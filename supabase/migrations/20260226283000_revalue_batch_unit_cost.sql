set app.allow_ledger_ddl = '1';

create or replace function public.revalue_batch_unit_cost(
  p_batch_id uuid,
  p_new_unit_cost numeric,
  p_reason text,
  p_post_journal boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch record;
  v_old_cost numeric;
  v_new_cost numeric;
  v_remaining numeric;
  v_delta_total numeric;
  v_inventory uuid;
  v_gain uuid;
  v_shrinkage uuid;
  v_entry_id uuid;
  v_lines jsonb;
  v_has_manual_journal boolean;
  v_has_approve boolean;
  v_item_id text;
  v_wh uuid;
  v_avg_cost numeric;
begin
  if not public.has_admin_permission('accounting.manage') then
    raise exception 'not allowed';
  end if;
  if p_batch_id is null then
    raise exception 'p_batch_id is required';
  end if;
  v_new_cost := coalesce(p_new_unit_cost, 0);
  if v_new_cost <= 0 then
    raise exception 'new unit cost must be > 0';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'reason is required';
  end if;

  select
    b.id,
    b.item_id::text as item_id,
    b.warehouse_id,
    coalesce(b.unit_cost, 0) as unit_cost,
    greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) as remaining_qty
  into v_batch
  from public.batches b
  where b.id = p_batch_id
  for update;
  if not found then
    raise exception 'batch not found';
  end if;

  v_item_id := v_batch.item_id;
  v_wh := v_batch.warehouse_id;
  v_old_cost := coalesce(v_batch.unit_cost, 0);
  v_remaining := coalesce(v_batch.remaining_qty, 0);

  update public.batches b
  set unit_cost = round(v_new_cost, 6),
      updated_at = now()
  where b.id = p_batch_id;

  v_delta_total := round((round(v_new_cost, 6) - round(v_old_cost, 6)) * coalesce(v_remaining, 0), 6);

  v_has_manual_journal :=
    to_regprocedure('public.create_manual_journal_entry(timestamptz,text,jsonb,uuid)') is not null;
  v_has_approve :=
    to_regprocedure('public.approve_journal_entry(uuid)') is not null;

  if coalesce(p_post_journal, true)
     and v_remaining > 0
     and abs(coalesce(v_delta_total, 0)) > 0.01
     and v_has_manual_journal
     and v_has_approve
     and to_regclass('public.journal_entries') is not null
     and to_regclass('public.journal_lines') is not null then
    v_inventory := public.get_account_id_by_code('1410');
    v_gain := public.get_account_id_by_code('4021');
    v_shrinkage := public.get_account_id_by_code('5020');

    if v_inventory is not null and v_gain is not null and v_shrinkage is not null then
      if v_delta_total > 0 then
        v_lines := jsonb_build_array(
          jsonb_build_object('accountCode', '1410', 'debit', v_delta_total, 'credit', 0, 'memo', 'Inventory revaluation increase'),
          jsonb_build_object('accountCode', '4021', 'debit', 0, 'credit', v_delta_total, 'memo', 'Inventory revaluation gain')
        );
      else
        v_lines := jsonb_build_array(
          jsonb_build_object('accountCode', '5020', 'debit', abs(v_delta_total), 'credit', 0, 'memo', 'Inventory revaluation loss'),
          jsonb_build_object('accountCode', '1410', 'debit', 0, 'credit', abs(v_delta_total), 'memo', 'Inventory revaluation decrease')
        );
      end if;

      select public.create_manual_journal_entry(
        now(),
        concat('Batch cost revaluation ', left(p_batch_id::text, 8), ' item ', coalesce(v_item_id, ''), ' (', coalesce(p_reason,''), ')'),
        v_lines,
        null
      ) into v_entry_id;

      perform public.approve_journal_entry(v_entry_id);
    end if;
  end if;

  with calc as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      sum(
        greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) * coalesce(b.unit_cost, 0)
      ) / nullif(
        sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)),
        0
      ) as avg_cost
    from public.batches b
    where b.item_id::text = v_item_id
      and b.warehouse_id = v_wh
      and coalesce(b.status, 'active') = 'active'
      and greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) > 0
    group by b.item_id::text, b.warehouse_id
  )
  update public.stock_management sm
  set
    avg_cost = round(coalesce(c.avg_cost, sm.avg_cost), 6),
    updated_at = now(),
    last_updated = now()
  from calc c
  where sm.item_id::text = c.item_id
    and sm.warehouse_id = c.warehouse_id;

  select sm.avg_cost into v_avg_cost
  from public.stock_management sm
  where sm.item_id::text = v_item_id
    and sm.warehouse_id = v_wh
  limit 1;

  update public.menu_items mi
  set
    cost_price = round(coalesce(v_avg_cost, mi.cost_price), 6),
    updated_at = now()
  where mi.id::text = v_item_id
    and coalesce(v_avg_cost, 0) > 0;

  if to_regclass('public.system_audit_logs') is not null then
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
    values (
      'batches.revalue_cost',
      'inventory',
      p_batch_id::text,
      auth.uid(),
      now(),
      jsonb_build_object(
        'batchId', p_batch_id::text,
        'itemId', v_item_id,
        'warehouseId', v_wh::text,
        'oldUnitCost', v_old_cost,
        'newUnitCost', v_new_cost,
        'remainingQty', v_remaining,
        'deltaTotal', v_delta_total,
        'journalEntryId', case when v_entry_id is null then null else v_entry_id::text end,
        'reason', p_reason
      ),
      'HIGH',
      'INVENTORY_REVALUATION'
    );
  end if;

  notify pgrst, 'reload schema';

  return jsonb_build_object(
    'batchId', p_batch_id::text,
    'itemId', v_item_id,
    'warehouseId', v_wh::text,
    'oldUnitCost', v_old_cost,
    'newUnitCost', v_new_cost,
    'remainingQty', v_remaining,
    'deltaTotal', v_delta_total,
    'journalEntryId', case when v_entry_id is null then null else v_entry_id::text end
  );
end;
$$;

revoke all on function public.revalue_batch_unit_cost(uuid, numeric, text, boolean) from public;
grant execute on function public.revalue_batch_unit_cost(uuid, numeric, text, boolean) to authenticated;

notify pgrst, 'reload schema';
