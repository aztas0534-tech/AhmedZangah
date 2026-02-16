
-- Diagnostic Script: Why are staff showing as customers?

-- 1. Check a sample of customers who *might* be staff (loose match on name/email)
SELECT 
    'potential_staff_in_customers' as diagnosis_type,
    c.auth_user_id,
    c.full_name as customer_name,
    c.email as customer_email,
    c.phone_number as customer_phone,
    
    -- Check if they are in admin_users by ID
    au.role as admin_role_by_id,
    au.is_active as admin_active_by_id,
    
    -- Check what the system function thinks
    public.is_system_user(c.auth_user_id) as is_system_user_flag,
    
    -- Check if they exist in admin_users by EMAIL (potential broken link)
    au_email.auth_user_id as admin_id_by_email,
    au_email.role as admin_role_by_email

FROM public.customers c
LEFT JOIN public.admin_users au ON au.auth_user_id = c.auth_user_id
LEFT JOIN public.admin_users au_email ON lower(au_email.email) = lower(c.email)
WHERE 
    -- Filter to suspicious records (likely staff names)
    c.full_name ILIKE '%owner%' 
    OR c.full_name ILIKE '%manager%' 
    OR c.full_name ILIKE '%admin%'
    OR c.email ILIKE '%admin%'
    OR c.email ILIKE '%owner%'
    -- Or just return the first 10 if we can't guess names
LIMIT 20;

-- 2. Check total counts
SELECT 
    (SELECT count(*) FROM public.customers) as total_customers,
    (SELECT count(*) FROM public.admin_users) as total_admin_users,
    (SELECT count(*) FROM public.customers c JOIN public.admin_users au ON au.auth_user_id = c.auth_user_id) as exact_id_overlap;
