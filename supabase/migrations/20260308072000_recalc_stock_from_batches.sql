-- ============================================================================
-- Repair: Recalculate stock_management from actual batch data
-- Fixes INSUFFICIENT_BATCH_STOCK errors where stock_management.available_quantity
-- is out of sync with actual batch remaining quantities.
-- ============================================================================

-- Recalculate available_quantity from batches for ALL items
update public.stock_management sm
set available_quantity = coalesce((
      select sum(
        greatest(
          coalesce(b.quantity_received, 0)
          - coalesce(b.quantity_consumed, 0)
          - coalesce(b.quantity_transferred, 0),
          0
        )
      )
      from public.batches b
      where b.item_id::text = sm.item_id::text
        and b.warehouse_id = sm.warehouse_id
        and coalesce(b.status, 'active') = 'active'
    ), 0),
    reserved_quantity = coalesce((
      select sum(r.quantity)
      from public.order_item_reservations r
      where r.item_id::text = sm.item_id::text
        and r.warehouse_id = sm.warehouse_id
    ), 0),
    last_updated = now(),
    updated_at = now();

-- Force PostgREST reload
notify pgrst, 'reload schema';
notify pgrst, 'reload config';
