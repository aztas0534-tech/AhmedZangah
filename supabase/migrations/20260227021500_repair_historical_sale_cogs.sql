set app.allow_ledger_ddl = '1';

-- ============================================================================
-- repair_historical_sale_cogs
-- Fixes past orders where COGS was recorded using inflated batch costs.
-- For each sale_out movement linked to a batch, if the movement's unit_cost
-- differs from the batch's current (corrected) unit_cost, we:
--   1. Update inventory_movements.unit_cost & total_cost
--   2. Update order_item_cogs.unit_cost & total_cost
--   3. Create a corrective journal entry (COGS adjustment)
-- Supports dry_run mode for preview.
-- ============================================================================

create or replace function public.repair_historical_sale_cogs(
  p_item_id text default null,       -- null = all items
  p_warehouse_id uuid default null,  -- null = all warehouses
  p_dry_run boolean default true     -- true = preview only
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec record;
  v_total_movements_fixed integer := 0;
  v_total_cogs_fixed integer := 0;
  v_total_journals_created integer := 0;
  v_total_delta numeric := 0;
  v_old_total numeric;
  v_new_total numeric;
  v_delta numeric;
  v_entry_id uuid;
  v_inv_acct uuid;
  v_cogs_acct uuid;
  v_has_manual_journal boolean;
  v_has_approve boolean;
  v_items_affected text[] := '{}';
begin
  if auth.uid() is null then
    if current_user not in ('postgres','supabase_admin') then
      raise exception 'not authenticated';
    end if;
  else
    if not public.has_admin_permission('accounting.manage') then
      raise exception 'ليس لديك صلاحية إصلاح التكلفة';
    end if;
  end if;

  v_inv_acct := public.get_account_id_by_code('1410');
  v_cogs_acct := public.get_account_id_by_code('5010');
  v_has_manual_journal :=
    to_regprocedure('public.create_manual_journal_entry(timestamptz,text,jsonb,uuid)') is not null;
  v_has_approve :=
    to_regprocedure('public.approve_journal_entry(uuid)') is not null;

  -- Find all sale_out movements where unit_cost doesn't match the batch's corrected cost
  for v_rec in
    select
      im.id as movement_id,
      im.item_id,
      im.quantity,
      im.unit_cost as old_unit_cost,
      im.total_cost as old_total_cost,
      im.reference_id as order_id,
      im.batch_id,
      im.warehouse_id,
      im.occurred_at,
      b.unit_cost as batch_unit_cost
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    where im.movement_type = 'sale_out'
      and im.batch_id is not null
      and b.unit_cost is not null
      and b.unit_cost > 0
      and abs(coalesce(im.unit_cost, 0) - b.unit_cost) > 0.01
      and (p_item_id is null or im.item_id = p_item_id)
      and (p_warehouse_id is null or im.warehouse_id = p_warehouse_id)
    order by im.occurred_at asc
    for update of im
  loop
    v_old_total := coalesce(v_rec.old_total_cost, v_rec.old_unit_cost * v_rec.quantity);
    v_new_total := round(v_rec.batch_unit_cost * v_rec.quantity, 6);
    v_delta := v_new_total - v_old_total;

    if abs(v_delta) < 0.01 then
      continue;
    end if;

    if not p_dry_run then
      -- 1. Update inventory_movements
      update public.inventory_movements
      set unit_cost = v_rec.batch_unit_cost,
          total_cost = v_new_total
      where id = v_rec.movement_id;

      -- 2. Update order_item_cogs (match by order + item + batch movement quantity)
      update public.order_item_cogs oic
      set unit_cost = v_rec.batch_unit_cost,
          total_cost = v_new_total
      where oic.order_id = v_rec.order_id::uuid
        and oic.item_id = v_rec.item_id
        and abs(oic.quantity - v_rec.quantity) < 0.01
        and abs(oic.unit_cost - v_rec.old_unit_cost) < 0.01;

      -- 3. Fix existing journal entries for this movement
      -- Find the old journal entry
      declare
        v_old_je_id uuid;
        v_old_je record;
      begin
        select je.id into v_old_je_id
        from public.journal_entries je
        where je.source_table = 'inventory_movements'
          and je.source_id = v_rec.movement_id::text
          and je.source_event = 'sale_out'
        limit 1;

        if v_old_je_id is not null then
          -- Update journal lines directly: COGS debit + Inventory credit
          update public.journal_lines jl
          set debit = case when jl.account_id = v_cogs_acct then v_new_total else 0 end,
              credit = case when jl.account_id = v_inv_acct then v_new_total else 0 end
          where jl.journal_entry_id = v_old_je_id
            and jl.account_id in (v_cogs_acct, v_inv_acct);
        else
          -- No existing journal entry — create a corrective one if delta is significant
          if v_has_manual_journal and v_has_approve and abs(v_delta) > 0.01 then
            declare
              v_lines jsonb;
            begin
              if v_delta < 0 then
                -- Old COGS was too high → reduce COGS, increase Inventory
                v_lines := jsonb_build_array(
                  jsonb_build_object('accountId', v_inv_acct, 'debit', abs(v_delta), 'credit', 0, 'memo', 'COGS correction: reduce inflated cost'),
                  jsonb_build_object('accountId', v_cogs_acct, 'debit', 0, 'credit', abs(v_delta), 'memo', 'COGS correction: reduce inflated cost')
                );
              else
                -- Old COGS was too low → increase COGS, decrease Inventory
                v_lines := jsonb_build_array(
                  jsonb_build_object('accountId', v_cogs_acct, 'debit', abs(v_delta), 'credit', 0, 'memo', 'COGS correction: increase understated cost'),
                  jsonb_build_object('accountId', v_inv_acct, 'debit', 0, 'credit', abs(v_delta), 'memo', 'COGS correction: increase understated cost')
                );
              end if;

              v_entry_id := public.create_manual_journal_entry(
                v_rec.occurred_at,
                concat('COGS repair: order=', left(v_rec.order_id, 8), ' item=', v_rec.item_id, ' old=', round(v_rec.old_unit_cost, 2), ' new=', round(v_rec.batch_unit_cost, 2)),
                v_lines,
                null
              );
              if v_has_approve and v_entry_id is not null then
                perform public.approve_journal_entry(v_entry_id);
                v_total_journals_created := v_total_journals_created + 1;
              end if;
            exception when others then
              raise notice 'repair_cogs: journal creation failed for movement %: %', v_rec.movement_id, sqlerrm;
            end;
          end if;
        end if;
      end;
    end if;

    v_total_movements_fixed := v_total_movements_fixed + 1;
    v_total_cogs_fixed := v_total_cogs_fixed + 1;
    v_total_delta := v_total_delta + v_delta;

    if not (v_rec.item_id = any(v_items_affected)) then
      v_items_affected := array_append(v_items_affected, v_rec.item_id);
    end if;
  end loop;

  return jsonb_build_object(
    'dryRun', p_dry_run,
    'movementsFixed', v_total_movements_fixed,
    'cogsRecordsFixed', v_total_cogs_fixed,
    'journalsCreated', v_total_journals_created,
    'totalDelta', round(v_total_delta, 2),
    'itemsAffected', array_length(v_items_affected, 1),
    'itemIds', to_jsonb(v_items_affected)
  );
end;
$$;

revoke all on function public.repair_historical_sale_cogs(text, uuid, boolean) from public;
grant execute on function public.repair_historical_sale_cogs(text, uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
