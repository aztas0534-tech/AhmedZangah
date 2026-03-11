-- Fix the quantity consumed calculation that caused batches to disappear.
-- The previous logic was: quantity_consumed = quantity_received - v_qty.
-- This was flawed because if v_qty (net movements) was 0 due to an unposted or purely-QC batch, 
-- it assumed quantity_consumed = quantity_received, making the batch look entirely depleted.
-- We must calculate quantity_consumed purely as the sum of outbound movements!

do $$
declare
  r record;
  v_consumed numeric;
  v_net numeric;
begin
  for r in
    select id
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
    set quantity_consumed = least(v_consumed, quantity_received), updated_at = now()
    where id = r.id;
    
    -- Ensure batch_balances accurately reflects the net of all movements.
    select coalesce(sum(
      case 
        when movement_type in ('purchase_in', 'adjust_in', 'transfer_in') then quantity
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
