-- Investigate QC stock for the specific item
do $$
declare
    v_item_id text := '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
    v_rec record;
begin
    raise notice '==================================================';
    raise notice 'CHECKING BATCHES IN QC FOR ITEM: %', v_item_id;
    for v_rec in 
        select id, batch_code, (quantity_received - quantity_consumed - quantity_transferred) as calc_qty, qc_status, status
        from public.batches
        where item_id = v_item_id and (qc_status != 'approved' or status = 'in_qc' or (quantity_received - quantity_consumed - quantity_transferred) > 0)
    loop
        raise notice 'Batch: %, Qty: %, QC: %, Status: %', v_rec.batch_code, v_rec.calc_qty, v_rec.qc_status, v_rec.status;
    end loop;

    raise notice '==================================================';
end $$;
