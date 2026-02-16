
-- Test Sales Report RPCs (bypass is_staff by running core logic directly)
-- We run as postgres superuser, so we skip the RPC wrappers and test the SQL directly.

-- 1. Sales Report Summary (mirrors get_sales_report_summary logic)
WITH effective_orders AS (
    SELECT
      o.id,
      o.status,
      o.created_at,
      coalesce(nullif(o.data->>'paymentMethod', ''), '') as payment_method,
      nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
      coalesce(o.fx_rate, 1) as fx_rate,
      coalesce(
        nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
        nullif(o.data->>'paidAt', '')::timestamptz,
        nullif(o.data->>'deliveredAt', '')::timestamptz,
        o.created_at
      ) as date_by,
      coalesce(
        o.base_total,
        coalesce(nullif((o.data->>'total')::numeric, null), 0) * coalesce(o.fx_rate, 1)
      ) as total,
      coalesce(nullif((o.data->>'taxAmount')::numeric, null), 0) * coalesce(o.fx_rate, 1) as tax_amount,
      coalesce(nullif((o.data->>'deliveryFee')::numeric, null), 0) * coalesce(o.fx_rate, 1) as delivery_fee,
      coalesce(
        nullif(o.data->>'discountAmount','')::numeric,
        nullif(o.data->>'discountTotal','')::numeric,
        nullif(o.data->>'discount','')::numeric,
        0
      ) * coalesce(o.fx_rate, 1) as discount_amount,
      coalesce(nullif(o.data->>'orderSource',''), '') as order_source,
      o.data
    FROM public.orders o
    WHERE nullif(trim(coalesce(o.data->>'voidedAt','')), '') IS NULL
),
filtered AS (
    SELECT *
    FROM effective_orders eo
    WHERE (
        eo.paid_at IS NOT NULL
        OR (eo.status = 'delivered' AND eo.payment_method <> 'cash')
    )
      AND eo.date_by >= now() - interval '1 day'
      AND eo.date_by <= now() + interval '1 day'
)
SELECT
    'summary_check' as check_type,
    json_build_object(
        'total_orders', count(*),
        'total_collected', coalesce(sum(f.total), 0),
        'total_tax', coalesce(sum(f.tax_amount), 0),
        'total_delivery_fee', coalesce(sum(f.delivery_fee), 0),
        'total_discounts', coalesce(sum(f.discount_amount), 0),
        'gross_subtotal', coalesce(sum(f.total - f.tax_amount - f.delivery_fee + f.discount_amount), 0),
        'in_store', count(*) filter (where f.order_source = 'in_store'),
        'online', count(*) filter (where f.order_source = 'online'),
        'statuses', json_agg(json_build_object('id', f.id, 'status', f.status, 'total', f.total, 'paid_at', f.paid_at))
    ) as result
FROM filtered f;

-- 2. COGS check (mirrors the COGS logic in the summary)
SELECT
    'cogs_check' as check_type,
    json_build_object(
        'total_cogs', coalesce(sum(oic.total_cost), 0),
        'cogs_entries', count(*),
        'details', json_agg(json_build_object('order_id', oic.order_id, 'item_id', oic.item_id, 'qty', oic.quantity, 'unit_cost', oic.unit_cost, 'total_cost', oic.total_cost))
    ) as result
FROM public.order_item_cogs oic
WHERE oic.order_id IN (
    SELECT o.id FROM public.orders o
    WHERE o.status = 'delivered'
      AND o.created_at >= now() - interval '1 day'
);

-- 3. Sales by Category (mirrors get_sales_by_category logic)
WITH effective_orders AS (
    SELECT
      o.id,
      o.data,
      o.status,
      nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
      coalesce(nullif(o.data->>'paymentMethod', ''), '') as payment_method,
      coalesce(
        nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
        nullif(o.data->>'paidAt', '')::timestamptz,
        nullif(o.data->>'deliveredAt', '')::timestamptz,
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
filtered_orders AS (
    SELECT *
    FROM effective_orders eo
    WHERE (
        eo.paid_at IS NOT NULL
        OR (eo.status = 'delivered' AND eo.payment_method <> 'cash')
    )
      AND eo.date_by >= now() - interval '1 day'
      AND eo.date_by <= now() + interval '1 day'
),
expanded_items AS (
    SELECT
      fo.id as order_id,
      fo.fx_rate,
      jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(fo.data->'invoiceSnapshot'->'items') = 'array' THEN fo.data->'invoiceSnapshot'->'items'
          WHEN jsonb_typeof(fo.data->'items') = 'array' THEN fo.data->'items'
          ELSE '[]'::jsonb
        END
      ) as item
    FROM filtered_orders fo
)
SELECT
    'category_check' as check_type,
    json_build_object(
        'categories', json_agg(json_build_object(
            'category', coalesce(nullif(ei.item->>'category',''), nullif(ei.item->>'categoryId',''), 'Uncategorized'),
            'item_id', ei.item->>'itemId',
            'quantity', coalesce((ei.item->>'quantity')::numeric, 0),
            'price', coalesce((ei.item->>'price')::numeric, 0),
            'line_total', coalesce((ei.item->>'price')::numeric, 0) * coalesce((ei.item->>'quantity')::numeric, 0) * ei.fx_rate
        ))
    ) as result
FROM expanded_items ei;

-- 4. Net Profit Calculation Verification
-- Expected: Revenue 100 - COGS 10 = Gross Profit 90 (90% margin)
SELECT
    'profit_check' as check_type,
    json_build_object(
        'expected_revenue', 100,
        'expected_cogs', 10,
        'expected_gross_profit', 90,
        'expected_margin_pct', 90.0,
        'actual_base_total', o.base_total,
        'actual_cogs', coalesce((SELECT sum(total_cost) FROM public.order_item_cogs WHERE order_id = o.id), 0),
        'actual_gross_profit', o.base_total - coalesce((SELECT sum(total_cost) FROM public.order_item_cogs WHERE order_id = o.id), 0),
        'match', (o.base_total = 100 AND coalesce((SELECT sum(total_cost) FROM public.order_item_cogs WHERE order_id = o.id), 0) = 10)
    ) as result
FROM public.orders o
WHERE o.id = '99999999-9999-4999-9999-999999999999';
