create extension if not exists pg_stat_statements;

create table if not exists public.pricing_rpc_logs (
  id uuid primary key default gen_random_uuid(),
  called_at timestamptz not null default now(),
  auth_role text,
  auth_user_id uuid,
  function_name text not null,
  item_id text,
  warehouse_id uuid,
  quantity numeric,
  currency_code text,
  customer_id uuid,
  suggested_price numeric,
  min_price numeric,
  batch_id uuid,
  reason_code text,
  context jsonb
);

revoke all on table public.pricing_rpc_logs from public;
revoke all on table public.pricing_rpc_logs from anon;
revoke all on table public.pricing_rpc_logs from authenticated;
grant select on table public.pricing_rpc_logs to service_role;

alter table public.pricing_rpc_logs enable row level security;
drop policy if exists pricing_rpc_logs_admin_select on public.pricing_rpc_logs;
create policy pricing_rpc_logs_admin_select on public.pricing_rpc_logs
  for select
  using (public.has_admin_permission('system.audit'));

create or replace function public.get_pitr_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := '{}'::jsonb;
  v_wal_level text;
  v_archive text;
  v_restore text;
  v_senders text;
begin
  begin v_wal_level := current_setting('wal_level', true); exception when others then v_wal_level := null; end;
  begin v_archive := current_setting('archive_mode', true); exception when others then v_archive := null; end;
  begin v_restore := current_setting('restore_command', true); exception when others then v_restore := null; end;
  begin v_senders := current_setting('max_wal_senders', true); exception when others then v_senders := null; end;
  v := jsonb_build_object(
    'wal_level', v_wal_level,
    'archive_mode', v_archive,
    'restore_command', v_restore,
    'max_wal_senders', v_senders
  );
  return v;
end;
$$;
revoke all on function public.get_pitr_status() from public;
grant execute on function public.get_pitr_status() to authenticated;
grant execute on function public.get_pitr_status() to service_role;

create table if not exists public.backup_settings (
  id text primary key default 'singleton',
  pitr_enabled boolean not null default true,
  retention_days integer not null default 7,
  updated_at timestamptz not null default now(),
  data jsonb
);

insert into public.backup_settings(id, pitr_enabled, retention_days)
values ('singleton', true, 7)
on conflict (id) do update set updated_at = now();

revoke all on table public.backup_settings from public;
revoke all on table public.backup_settings from anon;
grant select on table public.backup_settings to authenticated;
grant select, update on table public.backup_settings to service_role;

create or replace function public.get_fefo_pricing(
  p_item_id text,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_customer_id uuid default null,
  p_currency_code text default null
)
returns table (
  batch_id uuid,
  unit_cost numeric,
  min_price numeric,
  suggested_price numeric,
  batch_code text,
  expiry_date date,
  next_batch_min_price numeric,
  warning_next_batch_price_diff boolean,
  reason_code text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_qty numeric := greatest(coalesce(p_quantity, 0), 0);
  v_batch record;
  v_next record;
  v_base_price numeric := 0;
  v_total_released numeric := 0;
  v_has_nonexpired_unreleased boolean := false;
  v_currency text;
  v_auth text;
  v_user uuid;
begin
  if nullif(btrim(coalesce(p_item_id, '')), '') is null then
    raise exception 'p_item_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'p_warehouse_id is required';
  end if;
  if v_qty <= 0 then
    v_qty := 1;
  end if;

  select
    b.id,
    b.cost_per_unit,
    b.min_selling_price,
    b.batch_code,
    b.expiry_date,
    greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as remaining
  into v_batch
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
    and coalesce(b.qc_status,'released') = 'released'
  order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
  limit 1;

  select exists(
    select 1
    from public.batches b
    where b.item_id::text = p_item_id::text
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status, 'active') = 'active'
      and (b.expiry_date is null or b.expiry_date >= current_date)
      and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
      and coalesce(b.qc_status,'released') <> 'released'
  ) into v_has_nonexpired_unreleased;

  if v_batch.id is null then
    reason_code := case when v_has_nonexpired_unreleased then 'BATCH_NOT_RELEASED' else 'NO_VALID_BATCH' end;
    batch_id := null;
    unit_cost := null;
    min_price := 0;
    suggested_price := 0;
    batch_code := null;
    expiry_date := null;
    next_batch_min_price := null;
    warning_next_batch_price_diff := false;
    v_auth := auth.role();
    v_user := auth.uid();
    insert into public.pricing_rpc_logs(auth_role, auth_user_id, function_name, item_id, warehouse_id, quantity, currency_code, customer_id, suggested_price, min_price, batch_id, reason_code, context)
    values (v_auth, v_user, 'get_fefo_pricing', p_item_id, p_warehouse_id, v_qty, p_currency_code, p_customer_id, suggested_price, min_price, batch_id, reason_code, jsonb_build_object('stage','no_batch'));
    return next;
  end if;

  select coalesce(sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)), 0)
  into v_total_released
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and coalesce(b.qc_status,'released') = 'released';

  if v_total_released + 1e-9 < v_qty then
    reason_code := 'INSUFFICIENT_BATCH_QUANTITY';
  else
    reason_code := null;
  end if;

  v_currency := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  v_base_price := public.resolve_item_price(
    p_item_id::text,
    p_warehouse_id,
    coalesce(v_currency, public.get_base_currency()),
    v_qty,
    current_date,
    p_customer_id
  );

  batch_id := v_batch.id;
  unit_cost := case when auth.role() = 'service_role' then coalesce(v_batch.cost_per_unit, 0) else null end;
  min_price := coalesce(v_batch.min_selling_price, 0);
  suggested_price := greatest(coalesce(v_base_price, 0), coalesce(v_batch.min_selling_price, 0));
  batch_code := v_batch.batch_code;
  expiry_date := v_batch.expiry_date;

  select b.min_selling_price
  into v_next
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
    and coalesce(b.qc_status,'released') = 'released'
    and b.id <> v_batch.id
  order by b.expiry_date asc nulls last, b.created_at asc
  limit 1;

  next_batch_min_price := nullif(coalesce(v_next.min_selling_price, null), null);
  warning_next_batch_price_diff := case when next_batch_min_price is null then false else abs(next_batch_min_price - min_price) > 1e-9 end;

  v_auth := auth.role();
  v_user := auth.uid();
  insert into public.pricing_rpc_logs(auth_role, auth_user_id, function_name, item_id, warehouse_id, quantity, currency_code, customer_id, suggested_price, min_price, batch_id, reason_code, context)
  values (v_auth, v_user, 'get_fefo_pricing', p_item_id, p_warehouse_id, v_qty, p_currency_code, p_customer_id, suggested_price, min_price, batch_id, reason_code, jsonb_build_object('next_batch_min_price', next_batch_min_price, 'warning_next_batch_price_diff', warning_next_batch_price_diff));

  return next;
end;
$$;

revoke all on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) from public;
grant execute on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) to authenticated;

notify pgrst, 'reload schema';
