-- Check if admin_users (staff) also exist in customers table
SELECT
    'staff_as_customers_overlap' as check_type,
    json_build_object(
        'total_admin_users', (SELECT count(*) FROM public.admin_users),
        'total_customers', (SELECT count(*) FROM public.customers),
        'overlap_count', count(*),
        'overlap_details', json_agg(json_build_object(
            'auth_user_id', au.auth_user_id,
            'staff_role', au.role,
            'staff_name', au.full_name,
            'staff_username', au.username,
            'customer_name', c.full_name,
            'customer_phone', c.phone_number,
            'customer_loyalty_points', c.loyalty_points,
            'customer_total_spent', c.total_spent
        ))
    ) as result
FROM public.admin_users au
JOIN public.customers c ON c.auth_user_id = au.auth_user_id;

-- Check orders linked to admin users
SELECT
    'staff_orders_check' as check_type,
    json_build_object(
        'staff_with_orders', count(DISTINCT o.customer_id),
        'total_staff_orders', count(*),
        'sample', (
            SELECT json_agg(json_build_object(
                'order_id', s.id,
                'customer_id', s.customer_id,
                'staff_role', s.role,
                'staff_name', s.full_name,
                'total', s.total,
                'status', s.status
            ))
            FROM (
                SELECT o2.id, o2.customer_id, au2.role, au2.full_name,
                       coalesce(nullif(o2.data->>'total','')::numeric, 0) as total,
                       o2.status
                FROM public.orders o2
                JOIN public.admin_users au2 ON au2.auth_user_id = o2.customer_id
                LIMIT 5
            ) s
        )
    ) as result
FROM public.orders o
JOIN public.admin_users au ON au.auth_user_id = o.customer_id;
