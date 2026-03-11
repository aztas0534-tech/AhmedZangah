-- Run the EXACT same query as get_item_batches but without auth, to see what it returns
do $$
declare
    v_item_id text := '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
    v_wh uuid := '7628598d-3c02-4a55-b7db-76df1c421175'::uuid;
    v_rec record;
    v_count int := 0;
begin
    raise notice '========== SIMULATED get_item_batches QUERY ==========';
    for v_rec in 
        select
            b.id as batch_id,
            coalesce(b.created_at, max(im.occurred_at)) as occurred_at,
            coalesce(nullif(b.unit_cost, 0), max(im.unit_cost), 0) as unit_cost,
            coalesce(b.quantity_received, 0) as received_quantity,
            coalesce(b.quantity_consumed, 0) + coalesce(b.quantity_transferred, 0) as consumed_quantity,
            greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) as remaining_quantity,
            coalesce(b.qc_status,'released') as qc_status
        from public.batches b
        left join public.inventory_movements im on im.batch_id = b.id
        where b.item_id = v_item_id
            and b.warehouse_id = v_wh
            and coalesce(b.status,'active') = 'active'
        group by b.id, b.created_at, b.unit_cost, b.foreign_unit_cost, b.foreign_currency, b.fx_rate_at_receipt, b.quantity_received, b.quantity_consumed, b.quantity_transferred, b.qc_status
        having greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) > 0
        order by occurred_at desc
    loop
        v_count := v_count + 1;
        raise notice 'ROW %: batch_id=%, remaining=%, qc_status=%', 
            v_count, v_rec.batch_id, v_rec.remaining_quantity, v_rec.qc_status;
    end loop;
    raise notice 'Total rows returned: %', v_count;
    raise notice '========== END ==========';
end $$;
