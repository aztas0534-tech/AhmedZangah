
-- Fix: Final Purge - Remove Customers that ARE Admin Users (Same ID)
-- The previous scripts matched "duplicates" (different IDs).
-- This script removes records where the Customer ID *matches* the Admin ID, because Staff should not be in the Customers table at all.

DO $$
DECLARE
    v_customer_count integer;
    v_party_count integer;
    v_deleted_ids uuid[];
    v_party_ids uuid[];
BEGIN
    -- Identify Customers that are actually Admin Users (Direct ID Match)
    WITH staff_customers AS (
        SELECT c.auth_user_id
        FROM public.customers c
        JOIN public.admin_users au ON c.auth_user_id = au.auth_user_id
    )
    SELECT array_agg(auth_user_id) INTO v_deleted_ids FROM staff_customers;

    IF v_deleted_ids IS NULL OR array_length(v_deleted_ids, 1) = 0 THEN
        RAISE NOTICE 'No direct staff-customer matches found.';
        RETURN;
    END IF;

    -- 1. Get Financial Party IDs linked to these customers
    WITH target_parties AS (
        SELECT id FROM public.financial_parties
        WHERE linked_entity_type = 'customers' 
          AND linked_entity_id::uuid = ANY(v_deleted_ids)
    )
    SELECT array_agg(id) INTO v_party_ids FROM target_parties;

    -- 2. Delete from financial_party_links (FK dependency)
    IF v_party_ids IS NOT NULL AND array_length(v_party_ids, 1) > 0 THEN
        DELETE FROM public.financial_party_links
        WHERE party_id = ANY(v_party_ids);
    END IF;

    -- 3. Delete from financial_parties
    -- Note: We delete by ID now to be safe and precise
    IF v_party_ids IS NOT NULL AND array_length(v_party_ids, 1) > 0 THEN
        DELETE FROM public.financial_parties
        WHERE id = ANY(v_party_ids);
        
        v_party_count := array_length(v_party_ids, 1);
    ELSE
        v_party_count := 0;
    END IF;

    -- 4. Delete the Customers
    WITH deleted_customers AS (
        DELETE FROM public.customers
        WHERE auth_user_id = ANY(v_deleted_ids)
        RETURNING auth_user_id
    )
    SELECT count(*) INTO v_customer_count FROM deleted_customers;

    RAISE NOTICE 'Final Purge: Deleted % staff records masquerading as customers (Same ID) and % linked parties.', v_customer_count, v_party_count;
END $$;
