
-- Fix: Aggressive purge of duplicate staff accounts
-- The previous script missed cases where email matches name, or other variations.
-- This script matches broadly to find any customer account that looks like a staff member but has a different ID.

DO $$
DECLARE
    v_customer_count integer;
    v_party_count integer;
    v_deleted_ids uuid[];
    v_party_ids uuid[];
BEGIN
    -- Identify the Auth IDs of the duplicate customers using broad matching
    WITH duplicates AS (
        SELECT c.auth_user_id
        FROM public.customers c
        JOIN public.admin_users au ON 
            c.auth_user_id != au.auth_user_id -- IDs don't match (duplicate account)
            AND (
                -- Email matches anywhere
                lower(c.email) = lower(au.email) 
                OR lower(c.email) = lower(au.full_name)
                OR lower(c.email) = lower(au.username)
                -- Name matches anywhere
                OR lower(c.full_name) = lower(au.full_name)
                OR lower(c.full_name) = lower(au.email)
                OR lower(c.full_name) = lower(au.username)
                -- Fuzzy match for "Owner" or "Manager" if they are in the customer name/email
                OR (lower(c.full_name) ILIKE '%owner%' AND au.role = 'owner')
                OR (lower(c.email) ILIKE '%owner%' AND au.role = 'owner')
                OR (lower(c.full_name) ILIKE '%manager%' AND au.role = 'manager')
                OR (lower(c.email) ILIKE '%manager%' AND au.role = 'manager')
            )
    )
    SELECT array_agg(auth_user_id) INTO v_deleted_ids FROM duplicates;

    IF v_deleted_ids IS NULL OR array_length(v_deleted_ids, 1) = 0 THEN
        RAISE NOTICE 'No duplicate staff-customer accounts found with aggressive matching.';
        RETURN;
    END IF;

    -- 1. Get Financial Party IDs
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
    WITH deleted_parties AS (
        DELETE FROM public.financial_parties
        WHERE linked_entity_type = 'customers' 
          AND linked_entity_id::uuid = ANY(v_deleted_ids)
        RETURNING id
    )
    SELECT count(*) INTO v_party_count FROM deleted_parties;

    -- 4. Delete the Customers
    WITH deleted_customers AS (
        DELETE FROM public.customers
        WHERE auth_user_id = ANY(v_deleted_ids)
        RETURNING auth_user_id
    )
    SELECT count(*) INTO v_customer_count FROM deleted_customers;

    RAISE NOTICE 'Aggressive Purge: Deleted % duplicate customer records and % related financial parties.', v_customer_count, v_party_count;
END $$;
