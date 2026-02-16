set app.allow_ledger_ddl = '1';

do $$
declare
  v_invoice record;
  v_count int := 0;
begin
  -- Iterate key candidates: Open Invoices from Orders
  for v_invoice in
    select source_id
    from public.party_open_items
    where source_table = 'orders'
      and item_type = 'invoice'
      and status in ('open', 'partially_settled')
  loop
    begin
      perform public.match_order_payment_to_invoice(v_invoice.source_id::uuid);
      v_count := v_count + 1;
    exception when others then
      raise notice 'Failed to match order %', v_invoice.source_id;
    end;
    
    if v_count % 1000 = 0 then
      raise notice 'Processed % orders...', v_count;
    end if;
  end loop;
  
  raise notice 'Finished CODs Backfill. Processed candidates: %', v_count;
end $$;
