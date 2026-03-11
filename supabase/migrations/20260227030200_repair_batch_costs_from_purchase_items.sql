set app.allow_ledger_ddl = '1';

-- ============================================================================
-- Robust batch cost repair: use purchase_items base/qty conversion to convert purchase-unit cost to base-unit cost
-- ============================================================================

-- Disable only USER triggers (not system FK triggers)
alter table public.inventory_movements disable trigger user;

do $$
declare
  v_count int := 0;
  v_sm_count int := 0;
begin
  -- Fix batches where unit_cost equals the purchase_items.unit_cost (purchase UOM)
  -- but should be divided by the conversion factor
  with batch_fix as (
    select
      b.id as batch_id,
      b.item_id,
      b.warehouse_id,
      b.unit_cost as old_unit_cost,
      pi.unit_cost as pi_unit_cost,
      coalesce(
        (nullif(pi.qty_base, 0) / nullif(pi.quantity, 0)),
        (
          select nullif(iuu.qty_in_base, 0)
          from public.item_uom_units iuu
          where iuu.item_id::text = pi.item_id::text
            and iuu.is_active = true
            and iuu.qty_in_base > 1
          order by iuu.qty_in_base desc
          limit 1
        ),
        1
      ) as factor,
      round(b.unit_cost / nullif(coalesce(
        (nullif(pi.qty_base, 0) / nullif(pi.quantity, 0)),
        (
          select nullif(iuu.qty_in_base, 0)
          from public.item_uom_units iuu
          where iuu.item_id::text = pi.item_id::text
            and iuu.is_active = true
            and iuu.qty_in_base > 1
          order by iuu.qty_in_base desc
          limit 1
        ),
        1
      ), 0), 6) as new_unit_cost
    from public.batches b
    join public.purchase_receipts pr on pr.id = b.receipt_id
    join public.purchase_items pi on pi.purchase_order_id = pr.purchase_order_id
                                  and pi.item_id::text = b.item_id::text
    where b.receipt_id is not null
      and coalesce(b.unit_cost, 0) > 0
      and coalesce(
        (nullif(pi.qty_base, 0) / nullif(pi.quantity, 0)),
        (
          select nullif(iuu.qty_in_base, 0)
          from public.item_uom_units iuu
          where iuu.item_id::text = pi.item_id::text
            and iuu.is_active = true
            and iuu.qty_in_base > 1
          order by iuu.qty_in_base desc
          limit 1
        ),
        1
      ) > 1.0001
      -- Only fix if batch unit_cost matches purchase_items.unit_cost (meaning it wasn't divided)
      and abs(coalesce(b.unit_cost, 0) - coalesce(pi.unit_cost, 0)) < greatest(0.02, abs(coalesce(pi.unit_cost, 0)) * 0.05)
  )
  update public.batches b2
  set unit_cost = bf.new_unit_cost,
      updated_at = now()
  from batch_fix bf
  where b2.id = bf.batch_id
    and bf.new_unit_cost > 0
    and bf.factor > 1.0001;

  get diagnostics v_count = row_count;
  raise notice 'Fixed unit_cost for % batches', v_count;

  -- Also fix inventory_movements that have inflated unit_cost for purchase_in
  with mv_fix as (
    select
      im.id as movement_id,
      b.unit_cost as new_unit_cost
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    where im.movement_type = 'purchase_in'
      and coalesce(im.unit_cost, 0) > 0
      and coalesce(b.unit_cost, 0) > 0
      and abs(coalesce(im.unit_cost, 0) - coalesce(b.unit_cost, 0)) > 0.01
  )
  update public.inventory_movements im2
  set unit_cost = mf.new_unit_cost,
      total_cost = round(coalesce(im2.quantity, 0) * mf.new_unit_cost, 6)
  from mv_fix mf
  where im2.id = mf.movement_id;

  get diagnostics v_count = row_count;
  raise notice 'Fixed unit_cost for % purchase_in movements', v_count;

  -- Recalculate avg_cost for all stock records
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
    and sm.warehouse_id = c.warehouse_id;

  get diagnostics v_sm_count = row_count;
  raise notice 'Updated avg_cost for % stock records', v_sm_count;
end $$;

notify pgrst, 'reload schema';
