-- Final sweep to ensure batches table is fully synced
do $$
declare
    v_item_id text := '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
    v_correct_cost numeric := 12.15;
begin
    raise notice '==================================================';
    update public.batches
    set unit_cost = v_correct_cost,
        cost_per_unit = v_correct_cost
    where item_id = v_item_id;
    
    raise notice 'Updated batches. Rows affected: %', found;
    raise notice '==================================================';
end $$;
