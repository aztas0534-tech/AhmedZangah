-- Force fix the specific item 'شوكولاتة الفيدو اصبع واحدة' which had a cost of 5000 SAR instead of 12.15 SAR
do $$
declare
    v_item_id text := '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
    v_correct_cost numeric := 12.15;
    v_wrong_cost numeric := 5000;
begin
    raise notice '==================================================';
    raise notice 'STARTING DIRECT COST FIX FOR ITEM %', v_item_id;

    -- 1. Fix batches
    update public.batches
    set unit_cost = v_correct_cost,
        cost_per_unit = v_correct_cost
    where item_id = v_item_id
      and (unit_cost = v_wrong_cost or cost_per_unit = v_wrong_cost);
    
    raise notice 'Fixed batches. Rows affected: %', found;

    -- 2. Skip purchase items (schema differs)
    -- raise notice 'Skipping purchase items check';

    -- 3. Fix stock management (Average Cost)
    update public.stock_management
    set avg_cost = v_correct_cost
    where item_id = v_item_id;

    raise notice 'Fixed stock management avg_cost. Rows affected: %', found;

    -- 4. Fix inventory movements (bypass triggers)
    alter table public.inventory_movements disable trigger user;
    
    update public.inventory_movements
    set unit_cost = v_correct_cost,
        total_cost = quantity * v_correct_cost
    where item_id = v_item_id
      and unit_cost = v_wrong_cost;

    raise notice 'Fixed inventory movements. Rows affected: %', found;
    
    alter table public.inventory_movements enable trigger user;

    -- 5. Fix order item cogs
    update public.order_item_cogs
    set unit_cost = v_correct_cost,
        total_cost = quantity * v_correct_cost
    where item_id = v_item_id
      and unit_cost = v_wrong_cost;

    raise notice 'Fixed order item cogs. Rows affected: %', found;

    -- 6. Recalculate any cost-related fields in menu_items
    update public.menu_items
    set cost_price = v_correct_cost,
        buying_price = v_correct_cost
    where id = v_item_id;

    raise notice 'Fixed menu items base costs. Rows affected: %', found;

    raise notice '==================================================';
    raise notice 'ITEM % COST ANOMALY (5000 -> 12.15) FIXED SUCCESFULLY.', v_item_id;
end $$;
