do $$
declare
    v_rec record;
begin
    raise notice 'DEBUGGING INFLATED BATCHES (unit_cost > 1000):';
    for v_rec in (
        select b.id, b.item_id, b.unit_cost as batch_cost, b.receipt_id,
               pi.unit_cost as pi_cost, pi.quantity, pi.qty_base
        from public.batches b
        left join public.purchase_receipts pr on pr.id = b.receipt_id
        left join public.purchase_items pi on pi.purchase_order_id = pr.purchase_order_id 
                                       and pi.item_id::text = b.item_id::text
        where coalesce(b.unit_cost, 0) > 1000
    ) loop
        raise notice 'Batch % | Item % | Cost % | Receipt % | PI Cost % | q % | q_base %',
            v_rec.id, v_rec.item_id, v_rec.batch_cost, v_rec.receipt_id,
            v_rec.pi_cost, v_rec.quantity, v_rec.qty_base;
    end loop;
end $$;
