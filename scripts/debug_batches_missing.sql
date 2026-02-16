-- Diagnostic: Why are batches not showing for items with stock?
-- Run this against the live database to identify the root cause.

-- 1. Find items that have stock_management records but NO matching batches
SELECT 
    sm.item_id,
    mi.name->>'ar' as item_name,
    sm.warehouse_id,
    sm.available_quantity,
    sm.qc_hold_quantity,
    sm.avg_cost,
    sm.last_batch_id,
    (SELECT count(*) FROM public.batches b WHERE b.item_id = sm.item_id AND b.warehouse_id = sm.warehouse_id) as batch_count,
    (SELECT count(*) FROM public.batches b WHERE b.item_id = sm.item_id AND b.warehouse_id = sm.warehouse_id AND coalesce(b.status,'active') = 'active') as active_batch_count,
    (SELECT count(*) FROM public.batches b WHERE b.item_id = sm.item_id AND b.warehouse_id = sm.warehouse_id AND coalesce(b.status,'active') = 'active' AND greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0) as remaining_batch_count
FROM public.stock_management sm
JOIN public.menu_items mi ON mi.id = sm.item_id
WHERE sm.available_quantity > 0
ORDER BY batch_count asc, sm.available_quantity desc;

-- 2. Check if batches exist but warehouse_id doesn't match
SELECT 
    b.item_id,
    mi.name->>'ar' as item_name,
    b.warehouse_id as batch_wh,
    sm.warehouse_id as stock_wh,
    b.warehouse_id = sm.warehouse_id as wh_match,
    b.quantity_received,
    b.quantity_consumed,
    coalesce(b.quantity_transferred, 0) as quantity_transferred,
    greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as remaining,
    b.status,
    b.qc_status
FROM public.batches b
JOIN public.menu_items mi ON mi.id = b.item_id
LEFT JOIN public.stock_management sm ON sm.item_id = b.item_id AND sm.warehouse_id = b.warehouse_id
WHERE b.item_id IN (
    SELECT sm2.item_id FROM public.stock_management sm2 WHERE sm2.available_quantity > 0
)
ORDER BY b.item_id, b.created_at desc;

-- 3. Check for items with stock but zero batches at ALL
SELECT 
    sm.item_id,
    mi.name->>'ar' as item_name,
    sm.warehouse_id,
    sm.available_quantity,
    mi.is_food,
    mi.expiry_required,
    mi.category
FROM public.stock_management sm
JOIN public.menu_items mi ON mi.id = sm.item_id
WHERE sm.available_quantity > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.batches b WHERE b.item_id = sm.item_id
  )
ORDER BY sm.available_quantity desc;

-- 4. Check last_batch_id references
SELECT 
    sm.item_id,
    mi.name->>'ar' as item_name,
    sm.last_batch_id,
    b.id IS NOT NULL as batch_exists,
    b.warehouse_id as batch_wh,
    sm.warehouse_id as stock_wh,
    b.quantity_received,
    b.quantity_consumed
FROM public.stock_management sm
JOIN public.menu_items mi ON mi.id = sm.item_id
LEFT JOIN public.batches b ON b.id = sm.last_batch_id
WHERE sm.available_quantity > 0
  AND sm.last_batch_id IS NOT NULL
ORDER BY sm.available_quantity desc;

-- 5. Check inventory_movements for purchase_in without corresponding batches
SELECT 
    im.item_id,
    mi.name->>'ar' as item_name,
    im.batch_id,
    im.warehouse_id,
    im.quantity,
    im.occurred_at,
    b.id IS NOT NULL as batch_exists
FROM public.inventory_movements im
JOIN public.menu_items mi ON mi.id = im.item_id
LEFT JOIN public.batches b ON b.id = im.batch_id
WHERE im.movement_type = 'purchase_in'
  AND im.batch_id IS NOT NULL
  AND b.id IS NULL
ORDER BY im.occurred_at desc
LIMIT 20;
