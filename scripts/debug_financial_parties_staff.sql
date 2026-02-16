
-- Check for Financial Parties that match Staff Names
SELECT 
    'financial_party_staff_match' as check_type,
    fp.id,
    fp.name as party_name,
    fp.party_type,
    fp.linked_entity_type,
    fp.linked_entity_id,
    au.username as staff_username,
    au.role as staff_role
FROM public.financial_parties fp
JOIN public.admin_users au ON lower(au.full_name) = lower(fp.name) OR lower(au.username) = lower(fp.name)
WHERE fp.party_type = 'customer';

-- Check all Financial Parties of type 'customer' to see what's in there
SELECT * FROM public.financial_parties WHERE party_type = 'customer' LIMIT 20;
