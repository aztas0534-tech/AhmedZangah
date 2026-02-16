
-- Dump all customers (since there is only 1) to see who it is
SELECT 
    c.auth_user_id, 
    c.full_name, 
    c.email, 
    c.phone_number, 
    c.is_system_user, -- check if this column exists and what it says
    au.username as linked_admin_username
FROM public.customers c
LEFT JOIN public.admin_users au ON au.auth_user_id = c.auth_user_id;
