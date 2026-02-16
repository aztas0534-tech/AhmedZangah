
-- Debug supplier stock report: check if supplier_items exist
SELECT
    'supplier_items_check' as check_type,
    json_build_object(
        'total_supplier_items', count(*),
        'active_items', count(*) FILTER (WHERE si.is_active = true),
        'inactive_items', count(*) FILTER (WHERE si.is_active = false OR si.is_active IS NULL),
        'distinct_suppliers', count(DISTINCT si.supplier_id),
        'distinct_items', count(DISTINCT si.item_id),
        'sample', (SELECT json_agg(row_to_json(s)) FROM (SELECT si2.supplier_id, si2.item_id, si2.is_active FROM public.supplier_items si2 LIMIT 5) s)
    ) as result
FROM public.supplier_items si;

-- Check suppliers
SELECT
    'suppliers_check' as check_type,
    json_build_object(
        'total_suppliers', count(*),
        'sample', (SELECT json_agg(json_build_object('id', p.id, 'name', p.name, 'type', p.type)) FROM (SELECT * FROM public.parties WHERE type = 'supplier' LIMIT 5) p)
    ) as result
FROM public.parties
WHERE type = 'supplier';

-- Check if menu_items exist and are linked
SELECT
    'menu_items_status' as check_type,
    json_build_object(
        'total_items', count(*),
        'active_items', count(*) FILTER (WHERE mi.status = 'active'),
        'items_with_suppliers', (SELECT count(DISTINCT si.item_id) FROM public.supplier_items si WHERE si.is_active)
    ) as result
FROM public.menu_items mi;
