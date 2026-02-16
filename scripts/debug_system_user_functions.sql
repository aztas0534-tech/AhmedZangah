
-- Get definition of is_system_user
select pg_get_functiondef('public.is_system_user'::regproc);

-- Get definition of is_admin
select pg_get_functiondef('public.is_admin'::regproc);

-- Check permissions/roles for list_customers_directory (security definer?)
select prosrc, prosecdef from pg_proc where proname = 'list_customers_directory';
