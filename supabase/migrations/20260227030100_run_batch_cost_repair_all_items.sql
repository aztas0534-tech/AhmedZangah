set app.allow_ledger_ddl = '1';

-- Run the repair for ALL items (no item filter), large limit, NOT dry run
do $$
declare
  v_result jsonb;
begin
  -- Run repair for all items with inflated costs
  select public.repair_inflated_uom_costs_by_trx_qty(
    p_item_id := null,
    p_warehouse_id := null,
    p_limit := 2000,
    p_dry_run := false
  ) into v_result;

  raise notice 'Repair result: %', v_result::text;
end $$;

-- Also update stock_management avg_cost from corrected batches
do $$
declare
  v_count int := 0;
begin
  -- Recalculate avg_cost for ALL stock records based on current batch costs
  with calc as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      case
        when sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)) > 0
        then sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) * coalesce(b.unit_cost, 0))
             / nullif(sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)), 0)
        else 0
      end as avg_cost
    from public.batches b
    where coalesce(b.status, 'active') = 'active'
    group by b.item_id::text, b.warehouse_id
  )
  update public.stock_management sm
  set avg_cost = round(coalesce(c.avg_cost, 0), 6),
      updated_at = now(),
      last_updated = now()
  from calc c
  where sm.item_id::text = c.item_id
    and sm.warehouse_id = c.warehouse_id
    and abs(coalesce(sm.avg_cost, 0) - coalesce(round(c.avg_cost, 0), 0)) > 0.01;

  get diagnostics v_count = row_count;
  raise notice 'Updated avg_cost for % stock records', v_count;
end $$;

notify pgrst, 'reload schema';
