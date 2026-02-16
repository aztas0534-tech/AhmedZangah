
-- Fix: Delete duplicate customer accounts AND their financial parties
-- This handles the case where a staff member has a separate customer account with a different UUID.

DO $$
DECLARE
    v_customer_count integer;
    v_party_count integer;
    v_deleted_ids uuid[];
BEGIN
    -- Identify the Auth IDs of the duplicate customers
    WITH duplicates AS (
        SELECT c.auth_user_id
        FROM public.customers c
        JOIN public.admin_users au ON 
            (lower(c.email) = lower(au.email) OR lower(c.full_name) = lower(au.full_name))
            AND c.auth_user_id != au.auth_user_id -- IDs don't match
    )
    SELECT array_agg(auth_user_id) INTO v_deleted_ids FROM duplicates;

    IF v_deleted_ids IS NULL OR array_length(v_deleted_ids, 1) = 0 THEN
        RAISE NOTICE 'No duplicate staff-customer accounts found.';
        RETURN;
    END IF;

    -- 1. Delete associated Financial Parties first (to avoid orphans if no cascade)
    WITH deleted_parties AS (
        DELETE FROM public.financial_parties
        WHERE linked_entity_type = 'customers' 
          AND linked_entity_id::uuid = ANY(v_deleted_ids)
        RETURNING id
    )
    SELECT count(*) INTO v_party_count FROM deleted_parties;

    -- 2. Delete the Customers
    WITH deleted_customers AS (
        DELETE FROM public.customers
        WHERE auth_user_id = ANY(v_deleted_ids)
        RETURNING auth_user_id
    )
    SELECT count(*) INTO v_customer_count FROM deleted_customers;

    RAISE NOTICE 'Cleaned up system: Deleted % duplicate customer records and % related financial parties.', v_customer_count, v_party_count;
END $$;
