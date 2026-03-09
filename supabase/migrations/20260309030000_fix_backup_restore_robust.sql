-- =======================================================================
-- FIX: Robust Backup Restore System
--
-- Problems fixed:
-- 1. admin_wipe_all_tables_for_restore used hardcoded table names that
--    don't match the current schema (e.g. 'invoices' vs 'orders')
-- 2. admin_import_table_data did not disable triggers during import,
--    causing triggers to corrupt restored data
-- 3. admin_import_table_data assumed all tables have 'id' PK
-- 4. No session-variable bypass for trigger checks during restore
--
-- Solution: All functions now dynamically discover tables and PKs
--           from information_schema at runtime.
-- =======================================================================

set app.allow_ledger_ddl = '1';

-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ 1. DYNAMIC WIPE: Discovers ALL public tables and truncates them    │
-- └─────────────────────────────────────────────────────────────────────┘
create or replace function public.admin_wipe_all_tables_for_restore()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_table text;
  v_sql text;
  v_skip text[] := array[
    'schema_migrations',
    'supabase_migrations',
    'spatial_ref_sys',
    'geography_columns',
    'geometry_columns'
  ];
begin
  -- 1. Security check
  if not public.has_admin_permission('system.settings') then
    raise exception 'Unauthorized: Requires system.settings permission';
  end if;

  -- 2. Set bypass config so triggers don't block the wipe
  perform set_config('app.restore_in_progress', '1', true);  -- transaction-local

  -- 3. Dynamically discover ALL tables in public schema and truncate
  for v_table in
    select t.table_name
    from information_schema.tables t
    where t.table_schema = 'public'
      and t.table_type = 'BASE TABLE'
      and t.table_name not like 'pg_%'
      and t.table_name not like '_pg_%'
      and t.table_name != 'app_settings'  -- preserve system settings
    order by t.table_name
  loop
    if v_table = any(v_skip) then
      continue;
    end if;

    begin
      v_sql := format('TRUNCATE TABLE public.%I CASCADE', v_table);
      execute v_sql;
    exception when others then
      raise notice 'Could not truncate %: %', v_table, sqlerrm;
    end;
  end loop;
end;
$$;

revoke all on function public.admin_wipe_all_tables_for_restore() from public;
grant execute on function public.admin_wipe_all_tables_for_restore() to authenticated;


-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ 2. TRIGGER-SAFE IMPORT: Disables triggers, detects PK dynamically │
-- └─────────────────────────────────────────────────────────────────────┘
create or replace function public.admin_import_table_data(p_table text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted int := 0;
  v_sql text;
  v_pk_cols text;
  v_conflict_clause text;
begin
  -- 1. Security check
  if not public.has_admin_permission('system.settings') then
    raise exception 'Unauthorized: Requires system.settings permission';
  end if;

  -- 2. Validate table name against SQL injection
  if p_table !~ '^[a-zA-Z0-9_]+$' then
    raise exception 'Invalid table name: %', p_table;
  end if;

  -- 3. Validate input is array
  if jsonb_typeof(p_data) != 'array' then
    return jsonb_build_object('status', 'error', 'message', 'Data must be a JSON array');
  end if;

  if jsonb_array_length(p_data) = 0 then
    return jsonb_build_object('status', 'success', 'inserted_count', 0);
  end if;

  -- 4. Set bypass flag so triggers know we're restoring
  perform set_config('app.restore_in_progress', '1', true);

  -- 5. Disable ALL triggers on the target table
  begin
    execute format('ALTER TABLE public.%I DISABLE TRIGGER ALL', p_table);
  exception when others then
    raise notice 'Could not disable triggers on %: %', p_table, sqlerrm;
  end;

  -- 6. Dynamically detect the primary key column(s) for this table
  select string_agg(kcu.column_name, ', ' order by kcu.ordinal_position)
  into v_pk_cols
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on kcu.constraint_name = tc.constraint_name
    and kcu.table_schema = tc.table_schema
    and kcu.table_name = tc.table_name
  where tc.table_schema = 'public'
    and tc.table_name = p_table
    and tc.constraint_type = 'PRIMARY KEY';

  -- 7. Build the conflict clause
  if v_pk_cols is not null and v_pk_cols != '' then
    v_conflict_clause := format('ON CONFLICT (%s) DO NOTHING', v_pk_cols);
  else
    v_conflict_clause := '';
  end if;

  -- 8. Execute the insert
  begin
    v_sql := format(
      'INSERT INTO public.%I SELECT * FROM jsonb_populate_recordset(null::public.%I, $1) %s',
      p_table, p_table, v_conflict_clause
    );
    execute v_sql using p_data;
    get diagnostics v_inserted = row_count;
  exception when others then
    -- Fallback: try without conflict clause (will skip if dupes exist)
    begin
      v_sql := format(
        'INSERT INTO public.%I SELECT * FROM jsonb_populate_recordset(null::public.%I, $1)',
        p_table, p_table
      );
      execute v_sql using p_data;
      get diagnostics v_inserted = row_count;
    exception when others then
      -- Re-enable triggers before returning error
      begin
        execute format('ALTER TABLE public.%I ENABLE TRIGGER ALL', p_table);
      exception when others then null;
      end;
      return jsonb_build_object(
        'status', 'error',
        'message', sqlerrm,
        'table', p_table
      );
    end;
  end;

  -- 9. Re-enable ALL triggers on the target table
  begin
    execute format('ALTER TABLE public.%I ENABLE TRIGGER ALL', p_table);
  exception when others then
    raise notice 'Could not re-enable triggers on %: %', p_table, sqlerrm;
  end;

  return jsonb_build_object('status', 'success', 'inserted_count', v_inserted, 'table', p_table);
end;
$$;

revoke all on function public.admin_import_table_data(text, jsonb) from public;
grant execute on function public.admin_import_table_data(text, jsonb) to authenticated;


-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ 3. POST-RESTORE TRIGGER RE-SYNC: Recalculates computed fields      │
-- └─────────────────────────────────────────────────────────────────────┘
create or replace function public.admin_post_restore_resync()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_count int := 0;
  v_sm_count int := 0;
begin
  if not public.has_admin_permission('system.settings') then
    raise exception 'Unauthorized';
  end if;

  -- Resync batch cost_per_unit and min_selling_price from unit_cost
  update public.batches
  set cost_per_unit = coalesce(unit_cost, 0),
      min_selling_price = round(
        coalesce(unit_cost, 0) * (1 + greatest(0, coalesce(min_margin_pct, 0)) / 100), 4
      )
  where cost_per_unit is distinct from coalesce(unit_cost, 0)
     or min_selling_price is distinct from round(
          coalesce(unit_cost, 0) * (1 + greatest(0, coalesce(min_margin_pct, 0)) / 100), 4
        );
  get diagnostics v_batch_count = row_count;

  -- Resync stock_management avg_cost from batches
  with calc as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      case when sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)) > 0 then
        sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) * coalesce(b.unit_cost,0))
        / sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0))
      else 0 end as avg_cost
    from public.batches b
    where coalesce(b.status, 'active') = 'active'
    group by b.item_id, b.warehouse_id
  )
  update public.stock_management sm
  set avg_cost = coalesce(c.avg_cost, sm.avg_cost)
  from calc c
  where sm.item_id::text = c.item_id
    and sm.warehouse_id = c.warehouse_id
    and sm.avg_cost is distinct from c.avg_cost;
  get diagnostics v_sm_count = row_count;

  return jsonb_build_object(
    'status', 'success',
    'batches_resynced', v_batch_count,
    'stock_management_resynced', v_sm_count
  );
end;
$$;

revoke all on function public.admin_post_restore_resync() from public;
grant execute on function public.admin_post_restore_resync() to authenticated;

notify pgrst, 'reload schema';
