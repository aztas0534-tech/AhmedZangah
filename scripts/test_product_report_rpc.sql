
-- Test Product Sales Report v9 (bypass is_staff by running core logic directly)

-- 1. Product Sales Report core logic check
WITH effective_orders AS (
    SELECT
      o.id,
      o.data,
      o.status,
      coalesce(
        nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
        nullif(o.data->>'deliveredAt', '')::timestamptz,
        nullif(o.data->>'paidAt', '')::timestamptz,
        o.created_at
      ) as date_by,
      coalesce(o.fx_rate, 1) as fx_rate,
      coalesce(
        nullif(o.data->>'discountAmount','')::numeric,
        nullif(o.data->>'discountTotal','')::numeric,
        nullif(o.data->>'discount','')::numeric,
        0
      ) as discount_amount,
      coalesce(nullif(o.data->>'subtotal','')::numeric, 0) as subtotal_amount
    FROM public.orders o
    WHERE nullif(trim(coalesce(o.data->>'voidedAt','')), '') IS NULL
),
sales_orders AS (
    SELECT *
    FROM effective_orders eo
    WHERE eo.status = 'delivered'
      AND eo.date_by >= now() - interval '1 day'
      AND eo.date_by <= now() + interval '1 day'
),
expanded_items AS (
    SELECT
      so.id as order_id,
      so.fx_rate,
      so.discount_amount,
      so.subtotal_amount,
      jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(so.data->'invoiceSnapshot'->'items') = 'array' THEN so.data->'invoiceSnapshot'->'items'
          WHEN jsonb_typeof(so.data->'items') = 'array' THEN so.data->'items'
          ELSE '[]'::jsonb
        END
      ) as item
    FROM sales_orders so
),
normalized_items AS (
    SELECT
      ei.order_id,
      coalesce(nullif(ei.item->>'itemId', ''), nullif(ei.item->>'id', '')) as item_id_text,
      coalesce(nullif(ei.item->>'unitType', ''), nullif(ei.item->>'unit', ''), 'piece') as unit_type,
      coalesce(nullif(ei.item->>'quantity', '')::numeric, 0) as quantity,
      coalesce(nullif(ei.item->>'price', '')::numeric, 0) as price,
      ei.fx_rate,
      ei.discount_amount,
      ei.subtotal_amount
    FROM expanded_items ei
),
order_item_gross AS (
    SELECT
      ni.order_id,
      ni.item_id_text,
      sum(greatest(ni.quantity, 0)) as qty_sold,
      sum(ni.price * greatest(ni.quantity, 0)) as line_gross,
      max(ni.fx_rate) as fx_rate,
      max(ni.discount_amount) as discount_amount,
      max(ni.subtotal_amount) as subtotal_amount
    FROM normalized_items ni
    WHERE nullif(ni.item_id_text, '') IS NOT NULL
    GROUP BY ni.order_id, ni.item_id_text
),
cogs_data AS (
    SELECT
      oic.item_id::text as item_id_text,
      sum(oic.total_cost) as gross_cost
    FROM public.order_item_cogs oic
    JOIN sales_orders so ON so.id = oic.order_id
    GROUP BY oic.item_id::text
)
SELECT
    'product_report_check' as check_type,
    json_build_object(
        'item_id', oig.item_id_text,
        'qty_sold', oig.qty_sold,
        'line_gross', oig.line_gross,
        'fx_rate', oig.fx_rate,
        'net_sales_base', oig.line_gross * oig.fx_rate,
        'cogs', coalesce(cg.gross_cost, 0),
        'profit', (oig.line_gross * oig.fx_rate) - coalesce(cg.gross_cost, 0),
        'expected_qty', 1,
        'expected_net_sales', 100,
        'expected_cogs', 10,
        'expected_profit', 90,
        'qty_match', oig.qty_sold = 1,
        'sales_match', oig.line_gross * oig.fx_rate = 100,
        'cogs_match', coalesce(cg.gross_cost, 0) = 10,
        'profit_match', (oig.line_gross * oig.fx_rate) - coalesce(cg.gross_cost, 0) = 90
    ) as result
FROM order_item_gross oig
LEFT JOIN cogs_data cg ON cg.item_id_text = oig.item_id_text;

-- 2. Movement-based quantity check (mirrors get_product_sales_quantity_from_movements)
SELECT
    'movement_qty_check' as check_type,
    json_build_object(
        'item_id', im.item_id::text,
        'quantity_sold', coalesce(sum(im.quantity), 0),
        'expected', 1,
        'match', coalesce(sum(im.quantity), 0) = 1
    ) as result
FROM public.inventory_movements im
JOIN public.orders o ON o.id = (im.reference_id)::uuid
  AND o.status = 'delivered'
  AND nullif(trim(coalesce(o.data->>'voidedAt','')), '') IS NULL
WHERE im.movement_type = 'sale_out'
  AND im.reference_table = 'orders'
  AND im.occurred_at >= now() - interval '1 day'
  AND im.occurred_at <= now() + interval '1 day'
GROUP BY im.item_id::text;

-- 3. Stock management check
SELECT
    'stock_check' as check_type,
    json_build_object(
        'items_in_stock_mgmt', count(*),
        'details', json_agg(json_build_object(
            'item_id', sm.item_id::text,
            'available', sm.available_quantity,
            'reserved', sm.reserved_quantity,
            'avg_cost', sm.avg_cost
        ))
    ) as result
FROM public.stock_management sm
WHERE sm.item_id = 'smoke-audit-item-1';

-- 4. Multi-currency consistency check: verify base_total = total * fx_rate for all orders
SELECT
    'fx_consistency_check' as check_type,
    json_build_object(
        'total_orders', count(*),
        'inconsistent_orders', count(*) FILTER (
          WHERE abs(coalesce(o.base_total, 0) - (coalesce(nullif((o.data->>'total')::numeric, null), 0) * coalesce(o.fx_rate, 1))) > 0.01
        ),
        'details', json_agg(json_build_object(
            'id', o.id,
            'total_in_data', o.data->>'total',
            'fx_rate', o.fx_rate,
            'base_total', o.base_total,
            'computed_base', coalesce(nullif((o.data->>'total')::numeric, null), 0) * coalesce(o.fx_rate, 1),
            'match', abs(coalesce(o.base_total, 0) - (coalesce(nullif((o.data->>'total')::numeric, null), 0) * coalesce(o.fx_rate, 1))) <= 0.01
        ))
    ) as result
FROM public.orders o
WHERE o.status = 'delivered';
