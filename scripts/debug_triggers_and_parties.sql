
-- Check triggers on customers table
select 
    trigger_name,
    event_manipulation,
    action_statement,
    action_timing
from information_schema.triggers
where event_object_table = 'customers';

-- Check if any financial parties exist that are NOT linked to customers (manual entries?)
select * from public.financial_parties 
where party_type = 'customer' 
and (linked_entity_type is null or linked_entity_type != 'customers');
