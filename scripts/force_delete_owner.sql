
-- Force Delete the specific Owner Customer Record
-- Target UUID: 25b65f34-ce92-421d-abbd-b53a0bfcf4f6

DO $$
DECLARE
    v_target_id uuid := '25b65f34-ce92-421d-abbd-b53a0bfcf4f6';
    v_party_id uuid;
BEGIN
    RAISE NOTICE 'Starting Force Delete for Owner Customer ID: %', v_target_id;

    -- 1. Find the Financial Party ID
    SELECT id INTO v_party_id
    FROM public.financial_parties
    WHERE linked_entity_type = 'customers' 
      AND linked_entity_id::text = v_target_id::text;
      
    IF v_party_id IS NOT NULL THEN
        RAISE NOTICE 'Found Financial Party ID: %', v_party_id;
        
        -- 2. Delete Links
        DELETE FROM public.financial_party_links WHERE party_id = v_party_id;
        RAISE NOTICE 'Deleted Financial Party Links';
        
        -- 3. Delete Party
        DELETE FROM public.financial_parties WHERE id = v_party_id;
        RAISE NOTICE 'Deleted Financial Party';
    ELSE
        RAISE NOTICE 'No Financial Party found for this customer.';
    END IF;

    -- 4. Delete Customer Record
    DELETE FROM public.customers WHERE auth_user_id = v_target_id;
    RAISE NOTICE 'Deleted Customer Record for Owner.';
    
END $$;
