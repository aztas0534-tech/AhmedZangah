do $$
declare
    v_item_id text := '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
    v_rec record;
begin
    raise notice '==================================================';
    raise notice 'CHECKING STOCK_MANAGEMENT FOR ITEM: %', v_item_id;
    for v_rec in 
        select warehouse_id, available_quantity, qc_hold_quantity, reserved_quantity, data
        from public.stock_management
        where item_id = v_item_id
    loop
        raise notice 'Stock WH: %, Avail: %, QCHold: %, Rsvd: %, Data: %', 
            v_rec.warehouse_id, v_rec.available_quantity, v_rec.qc_hold_quantity, v_rec.reserved_quantity, v_rec.data::text;
    end loop;
    raise notice '==================================================';
end $$;
