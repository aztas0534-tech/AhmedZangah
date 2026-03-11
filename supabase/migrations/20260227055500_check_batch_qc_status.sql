-- Check batches for this item
do $$
declare
    v_item_id text := '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
    v_rec record;
begin
    raise notice '==================================================';
    for v_rec in 
        select id, warehouse_id, quantity_received, quantity_consumed, quantity_transferred, qc_status, status
        from public.batches
        where item_id = v_item_id
    loop
        raise notice 'Batch ID: %, WH: %, Qty: %, QC: %, Status: %', 
            v_rec.id, v_rec.warehouse_id, (v_rec.quantity_received - v_rec.quantity_consumed - v_rec.quantity_transferred), v_rec.qc_status, v_rec.status;
    end loop;
    raise notice '==================================================';
end $$;
