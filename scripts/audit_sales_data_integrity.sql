
-- Audit Sales Data Integrity
-- 1. Check for missing base_total
-- 2. Check for missing COGS (order_item_cogs)
-- 3. Check for FX Rate anomalies

WITH base_currency AS (
    SELECT public.get_base_currency() as code
),
counts_check AS (
    SELECT 
        (SELECT count(*) FROM public.orders) as total_orders,
        (SELECT count(*) FROM public.menu_items) as total_menu_items,
        (SELECT count(*) FROM public.financial_parties) as total_parties,
        (SELECT count(*) FROM public.journal_entries) as total_journals,
        (SELECT count(*) FROM public.party_ledger_entries) as total_ledger_entries,
        (SELECT count(*) FROM public.order_item_cogs) as total_cogs
),
orders_check AS (
    SELECT 
        count(*) as total_orders_all,
        count(*) filter (where status = 'delivered') as total_delivered,
        count(*) filter (where base_total is null) as missing_base_total,
        count(*) filter (
            where currency is distinct from (select code from base_currency) 
            and (fx_rate is null or fx_rate = 1)
        ) as suspicious_fx_rate,
        count(*) filter (
            where status = 'delivered' 
            and not exists (select 1 from public.order_item_cogs oic where oic.order_id = orders.id)
        ) as missing_cogs
    FROM public.orders
),
cogs_verification AS (
    -- Compare order_item_cogs sum vs inventory_movements sale_out sum for valid orders
    SELECT 
        o.id,
        (select sum(total_cost) from public.order_item_cogs where order_id = o.id) as cogs_table_sum,
        (select sum(abs(total_cost)) from public.inventory_movements where reference_table = 'orders' and reference_id = o.id::text and movement_type = 'sale_out') as movements_sum
    FROM public.orders o
    WHERE o.status = 'delivered'
    LIMIT 100
)
SELECT 
    'Database Counts' as check_type,
    json_build_object(
        'orders', (select total_orders from counts_check),
        'menu_items', (select total_menu_items from counts_check),
        'financial_parties', (select total_parties from counts_check),
        'journal_entries', (select total_journals from counts_check),
        'ledger_entries', (select total_ledger_entries from counts_check),
        'cogs_entries', (select total_cogs from counts_check)
    ) as result
UNION ALL
SELECT 
    'Orders Summary' as check_type,
    json_build_object(
        'total_orders_all', total_orders_all,
        'total_delivered', total_delivered,
        'missing_base_total', missing_base_total,
        'suspicious_fx_rate', suspicious_fx_rate,
        'missing_cogs', missing_cogs
    ) as result
FROM orders_check
UNION ALL
SELECT
    'All Orders Details' as check_type,
    json_agg(
        json_build_object(
            'id', id,
            'status', status,
            'payment_status', coalesce(data->>'paymentStatus', 'unknown'),
            'delivery_status', coalesce(data->>'deliveryStatus', 'unknown'),
            'total', total,
            'base_total', base_total,
            'cogs_count', (select count(*) from public.order_item_cogs where order_id = orders.id)
        )
    ) as result
FROM public.orders;
