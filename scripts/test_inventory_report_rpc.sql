
-- Test Inventory Stock Report RPCs

-- 1. Check stock_management table integrity
SELECT
    'stock_mgmt_check' as check_type,
    json_build_object(
        'total_items', count(*),
        'negative_available', count(*) FILTER (WHERE sm.available_quantity < 0),
        'negative_reserved', count(*) FILTER (WHERE sm.reserved_quantity < 0),
        'reserved_exceeds_available', count(*) FILTER (WHERE sm.reserved_quantity > sm.available_quantity),
        'null_warehouse', count(*) FILTER (WHERE sm.warehouse_id IS NULL),
        'null_item', count(*) FILTER (WHERE sm.item_id IS NULL)
    ) as result
FROM public.stock_management sm;

-- 2. Inventory movement consistency check
-- Verify available_quantity = sum(ins) - sum(outs) from movements
WITH movement_totals AS (
    SELECT
        im.item_id,
        im.warehouse_id,
        coalesce(sum(im.quantity) FILTER (WHERE im.movement_type IN ('purchase_in', 'adjust_in', 'return_in', 'transfer_in')), 0) as total_in,
        coalesce(sum(im.quantity) FILTER (WHERE im.movement_type IN ('sale_out', 'wastage_out', 'adjust_out', 'return_out', 'transfer_out')), 0) as total_out
    FROM public.inventory_movements im
    GROUP BY im.item_id, im.warehouse_id
),
stock_vs_movements AS (
    SELECT
        sm.item_id,
        sm.warehouse_id,
        sm.available_quantity as stock_qty,
        coalesce(mt.total_in, 0) - coalesce(mt.total_out, 0) as movement_net,
        abs(sm.available_quantity - (coalesce(mt.total_in, 0) - coalesce(mt.total_out, 0))) as diff
    FROM public.stock_management sm
    LEFT JOIN movement_totals mt ON mt.item_id = sm.item_id AND mt.warehouse_id = sm.warehouse_id
)
SELECT
    'movement_vs_stock_check' as check_type,
    json_build_object(
        'total_items', count(*),
        'mismatched_items', count(*) FILTER (WHERE diff > 0.01),
        'max_diff', max(diff),
        'sample_mismatches', (
            SELECT json_agg(json_build_object('item_id', s.item_id, 'stock_qty', s.stock_qty, 'movement_net', s.movement_net, 'diff', s.diff))
            FROM (SELECT * FROM stock_vs_movements WHERE diff > 0.01 LIMIT 5) s
        )
    ) as result
FROM stock_vs_movements;

-- 3. Batch integrity check
SELECT
    'batch_check' as check_type,
    json_build_object(
        'total_batches', count(*),
        'negative_qty_received', count(*) FILTER (WHERE b.quantity_received < 0),
        'negative_unit_cost', count(*) FILTER (WHERE b.unit_cost < 0),
        'zero_unit_cost', count(*) FILTER (WHERE b.unit_cost = 0 AND b.status = 'active'),
        'null_warehouse', count(*) FILTER (WHERE b.warehouse_id IS NULL),
        'null_item', count(*) FILTER (WHERE b.item_id IS NULL),
        'active_batches', count(*) FILTER (WHERE b.status = 'active'),
        'expired_batches', count(*) FILTER (WHERE b.expiry_date IS NOT NULL AND b.expiry_date < now())
    ) as result
FROM public.batches b;

-- 4. Cost price consistency: compare avg_cost in stock_management with batch unit_cost
WITH batch_avg AS (
    SELECT
        b.item_id,
        b.warehouse_id,
        avg(b.unit_cost) FILTER (WHERE b.status = 'active' AND b.quantity_received > 0) as avg_batch_cost
    FROM public.batches b
    GROUP BY b.item_id, b.warehouse_id
)
SELECT
    'cost_consistency_check' as check_type,
    json_build_object(
        'total_items', count(*),
        'items_with_cost_data', count(*) FILTER (WHERE sm.avg_cost IS NOT NULL AND sm.avg_cost > 0),
        'items_with_batch_cost', count(*) FILTER (WHERE ba.avg_batch_cost IS NOT NULL),
        'large_cost_discrepancy', count(*) FILTER (
            WHERE ba.avg_batch_cost IS NOT NULL AND sm.avg_cost > 0
            AND abs(sm.avg_cost - ba.avg_batch_cost) / greatest(sm.avg_cost, 0.01) > 0.5
        )
    ) as result
FROM public.stock_management sm
LEFT JOIN batch_avg ba ON ba.item_id = sm.item_id AND ba.warehouse_id = sm.warehouse_id;

-- 5. Inventory movements with currency info check
SELECT
    'movement_currency_check' as check_type,
    json_build_object(
        'total_movements', count(*),
        'null_unit_cost', count(*) FILTER (WHERE im.unit_cost IS NULL),
        'negative_unit_cost', count(*) FILTER (WHERE im.unit_cost < 0),
        'null_total_cost', count(*) FILTER (WHERE im.total_cost IS NULL),
        'zero_qty_movements', count(*) FILTER (WHERE im.quantity = 0),
        'movement_types', (SELECT json_agg(DISTINCT im2.movement_type) FROM public.inventory_movements im2)
    ) as result
FROM public.inventory_movements im;
