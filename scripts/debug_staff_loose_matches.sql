
-- Check for Financial Parties linked to Admin Users (as customers)
SELECT 
    'financial_party_check' as check_type,
    fp.id, 
    fp.name, 
    fp.party_type, 
    fp.linked_entity_type, 
    fp.linked_entity_id,
    au.username as admin_username,
    au.role as admin_role
FROM public.financial_parties fp
JOIN public.admin_users au ON au.auth_user_id::text = fp.linked_entity_id
WHERE fp.party_type = 'customer';

-- Check for loose matches (Name/Phone) between Admin Users and Customers
-- This finds cases where a staff member might have created a separate customer account for themselves
SELECT 
    'loose_match_check' as check_type,
    au.username as staff_username,
    au.full_name as staff_name,
    au.phone_number as staff_phone,
    c.auth_user_id as customer_id,
    c.full_name as customer_name,
    c.phone_number as customer_phone,
    c.auth_user_id as customer_auth_id
FROM public.admin_users au
JOIN public.customers c ON 
    (regexp_replace(au.phone_number, '\D', '', 'g') = regexp_replace(c.phone_number, '\D', '', 'g') AND au.phone_number IS NOT NULL AND length(au.phone_number) > 5)
    OR 
    (lower(au.full_name) = lower(c.full_name) AND au.full_name IS NOT NULL);

-- Check for loose matches between Admin Users and Financial Parties
SELECT 
    'financial_party_loose_match' as check_type,
    au.username as staff_username,
    au.full_name as staff_name,
    fp.name as party_name,
    fp.party_type
FROM public.admin_users au
JOIN public.financial_parties fp ON lower(au.full_name) = lower(fp.name)
WHERE fp.party_type = 'customer';

-- Helper function stub for query (if not exists)
-- Assuming simple equality for now, or use ILIKE
