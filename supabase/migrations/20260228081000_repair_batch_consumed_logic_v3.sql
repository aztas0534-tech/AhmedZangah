-- Fix the quantity consumed calculation to properly include return_in
do $$
declare
  r record;
  v_consumed numeric;
  v_net numeric;
begin
  for r in
    select id, quantity_received
    from public.batches
  loop
    -- Calculate precise outbound consumptions.
    select coalesce(sum(quantity), 0)
    into v_consumed
    from public.inventory_movements
    where batch_id = r.id
      and movement_type in ('sale_out', 'return_out', 'wastage_out', 'adjust_out', 'transfer_out');

    -- Update batches to solely reflect ACTUAL consumptions out of the door, 
    -- capped at received to satisfy the 'batches_qty_consistency' check constraint.
    update public.batches
    set quantity_consumed = least(v_consumed, r.quantity_received), updated_at = now()
    where id = r.id;
    
    -- Ensure batch_balances accurately reflects the net of all movements.
    select coalesce(sum(
      case 
        when movement_type in ('purchase_in', 'adjust_in', 'transfer_in', 'return_in') then quantity
        when movement_type in ('sale_out', 'return_out', 'wastage_out', 'adjust_out', 'transfer_out') then -quantity
        else 0
      end
    ), 0)
    into v_net
    from public.inventory_movements
    where batch_id = r.id;

    if v_net < 0 then
      v_net := 0; 
    end if;

    update public.batch_balances
    set quantity = v_net, updated_at = now()
    where batch_id = r.id;
    
  end loop;
end;
$$;

notify pgrst, 'reload schema';
