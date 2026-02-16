
-- Check RLS on admin_users
select * from pg_policies where tablename = 'admin_users';

-- Check list_customers_directory RPC
select pg_get_functiondef('public.list_customers_directory'::regproc);

-- Check for mixed users and their is_system_user flag
select
    au.username,
    au.role,
    c.full_name as customer_name,
    c.is_system_user
from public.customers c
join public.admin_users au on au.auth_user_id = c.auth_user_id;
