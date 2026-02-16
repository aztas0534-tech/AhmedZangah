
-- Check schema of financial_parties to be sure
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'financial_parties';

-- Investigate the remaining Owner party (searching by name only)
SELECT * 
FROM public.financial_parties 
WHERE name ILIKE '%owner%';
