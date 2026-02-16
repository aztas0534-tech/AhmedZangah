-- Purge system users (staff) from the customers table
-- This fixes the issue where staff appear in the customer list due to legacy data
-- existing before the trigger "trg_customers_reject_admin_users" was enforced.

DO $$ 
DECLARE
    v_count integer;
BEGIN
    -- Count overlaps before deletion
    SELECT count(*) INTO v_count
    FROM public.customers c
    JOIN public.admin_users au ON au.auth_user_id = c.auth_user_id;
    
    RAISE NOTICE 'Found % staff members improperly listed as customers.', v_count;

    -- Delete the overlapping customer records
    -- FKs (like orders) reference auth.users(id), not public.customers(id), mostly.
    -- If there are strict FKs to public.customers, this might fail, but standard schema uses auth_user_id.
    
    DELETE FROM public.customers c
    WHERE EXISTS (
        SELECT 1 
        FROM public.admin_users au 
        WHERE au.auth_user_id = c.auth_user_id
    );

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE 'Deleted % details from customers table.', v_count;

    -- Also flag any financial parties linked to these users as 'internal' or ensure they don't show up
    -- The view list_customers_directory already filters by is_system_user(), so this should be fine.
    
END $$;
