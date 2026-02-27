-- Debug: dump all columns of the pending batch to find why get_item_batches filters it
do $$
declare
    v_rec record;
begin
    raise notice '========== PENDING BATCH FULL DUMP ==========';
    for v_rec in 
        select 
            b.id,
            b.item_id,
            b.warehouse_id,
            b.status,
            b.qc_status,
            b.quantity_received,
            b.quantity_consumed,
            b.quantity_transferred,
            greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as calc_remaining,
            b.unit_cost,
            b.created_at,
            b.batch_code,
            b.data
        from public.batches b
        where b.item_id = '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a'
          and b.warehouse_id = '7628598d-3c02-4a55-b7db-76df1c421175'::uuid
          and coalesce(b.status,'active') = 'active'
    loop
        raise notice 'ID: %, QC: %, Status: %, qty_recv: %, qty_cons: %, qty_trans: %, remaining: %, cost: %, code: %', 
            v_rec.id, v_rec.qc_status, v_rec.status,
            v_rec.quantity_received, v_rec.quantity_consumed, v_rec.quantity_transferred,
            v_rec.calc_remaining, v_rec.unit_cost, v_rec.batch_code;
    end loop;
    raise notice '========== END DUMP ==========';
end $$;
