-- ============================================================================
-- FIX: revalue_batch_unit_cost should also update foreign_unit_cost
--      so that get_item_batches doesn't recalculate back to the old value
-- ============================================================================

create or replace function public.revalue_batch_unit_cost(
  p_batch_id uuid,
  p_new_unit_cost numeric,
  p_reason text default null,
  p_post_journal boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch record;
  v_item_id text;
  v_wh uuid;
  v_old_cost numeric;
  v_new_cost numeric;
  v_remaining numeric;
  v_delta_total numeric;
  v_has_manual_journal boolean;
  v_has_approve boolean;
  v_entry_id uuid;
  v_old_avg numeric;
  v_new_avg numeric;
  v_total_stock numeric;
  v_old_foreign numeric;
  v_new_foreign numeric;
begin
  if auth.uid() is null then
    if current_user not in ('postgres','supabase_admin') then
      raise exception 'not authenticated';
    end if;
  else
    if not public.has_admin_permission('accounting.manage') then
      raise exception 'ليس لديك صلاحية تعديل التكلفة';
    end if;
  end if;
  if p_batch_id is null then raise exception 'p_batch_id is required'; end if;

  v_new_cost := coalesce(p_new_unit_cost, 0);
  if v_new_cost <= 0 then raise exception 'unit cost must be > 0'; end if;

  select
    b.item_id, b.warehouse_id, b.unit_cost,
    b.foreign_unit_cost, b.fx_rate_at_receipt, b.foreign_currency,
    greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) as remaining_qty
  into v_batch
  from public.batches b
  where b.id = p_batch_id
    and coalesce(b.status, 'active') = 'active'
  for update;
  if not found then raise exception 'batch not found'; end if;

  v_item_id := v_batch.item_id;
  v_wh := v_batch.warehouse_id;
  v_old_cost := coalesce(v_batch.unit_cost, 0);
  v_remaining := coalesce(v_batch.remaining_qty, 0);

  -- FIX: Also update foreign_unit_cost if the batch has FX data
  v_old_foreign := v_batch.foreign_unit_cost;
  v_new_foreign := null;
  if v_batch.fx_rate_at_receipt is not null and v_batch.fx_rate_at_receipt > 0 and v_batch.foreign_currency is not null then
    v_new_foreign := round(v_new_cost / v_batch.fx_rate_at_receipt, 6);
  end if;

  update public.batches b
  set unit_cost = round(v_new_cost, 6),
      foreign_unit_cost = coalesce(v_new_foreign, b.foreign_unit_cost),
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
  then
    declare
      v_inv_acct uuid;
      v_adj_acct uuid;
      v_lines jsonb;
    begin
      v_inv_acct := public.get_account_id_by_code('1410');
      v_adj_acct := public.get_account_id_by_code('5020');
      if v_inv_acct is null or v_adj_acct is null then
        raise notice 'revalue_batch: cannot post — missing accounts';
      else
        if v_delta_total > 0 then
          v_lines := jsonb_build_array(
            jsonb_build_object('accountId', v_inv_acct, 'debit', abs(v_delta_total), 'credit', 0, 'memo', concat('Batch revaluation +', p_reason)),
            jsonb_build_object('accountId', v_adj_acct, 'debit', 0, 'credit', abs(v_delta_total), 'memo', concat('Cost adjustment ', p_reason))
          );
        else
          v_lines := jsonb_build_array(
            jsonb_build_object('accountId', v_adj_acct, 'debit', abs(v_delta_total), 'credit', 0, 'memo', concat('Cost adjustment ', p_reason)),
            jsonb_build_object('accountId', v_inv_acct, 'debit', 0, 'credit', abs(v_delta_total), 'memo', concat('Batch revaluation -', p_reason))
          );
        end if;
        v_entry_id := public.create_manual_journal_entry(
          now(),
          concat('Batch cost revaluation: ', left(p_batch_id::text, 8), ' item=', v_item_id, ' ', coalesce(p_reason, '')),
          v_lines,
          null
        );
        if v_has_approve and v_entry_id is not null then
          perform public.approve_journal_entry(v_entry_id);
        end if;
      end if;
    exception when others then
      raise notice 'revalue_batch: GL post failed — %', sqlerrm;
    end;
  end if;

  -- Recalculate avg_cost in stock_management
  select coalesce(sum(
    greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
    * coalesce(b.unit_cost, 0)
  ), 0) / nullif(sum(
    greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
  ), 0)
  into v_new_avg
  from public.batches b
  where b.item_id = v_item_id
    and b.warehouse_id = v_wh
    and coalesce(b.status, 'active') = 'active'
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0;

  if v_new_avg is not null then
    update public.stock_management
    set avg_cost = round(v_new_avg, 6), updated_at = now(), last_updated = now()
    where item_id::text = v_item_id and warehouse_id = v_wh;

    update public.menu_items
    set cost_price = round(v_new_avg, 6), updated_at = now()
    where id = v_item_id;
  end if;

  return jsonb_build_object(
    'batchId', p_batch_id,
    'oldUnitCost', v_old_cost,
    'newUnitCost', round(v_new_cost, 6),
    'oldForeignUnitCost', v_old_foreign,
    'newForeignUnitCost', v_new_foreign,
    'deltaTotal', v_delta_total,
    'remaining', v_remaining,
    'avgCost', v_new_avg
  );
end;
$$;

revoke all on function public.revalue_batch_unit_cost(uuid, numeric, text, boolean) from public;
grant execute on function public.revalue_batch_unit_cost(uuid, numeric, text, boolean) to authenticated;

notify pgrst, 'reload schema';
