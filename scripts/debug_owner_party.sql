
-- Investigate the remaining Owner party
SELECT * 
FROM public.financial_parties 
WHERE name ILIKE '%owner%' OR email ILIKE '%owner%';

-- Also check if there are any remaining customers with 'owner' in the name
SELECT * 
FROM public.customers 
WHERE full_name ILIKE '%owner%' OR email ILIKE '%owner%';
