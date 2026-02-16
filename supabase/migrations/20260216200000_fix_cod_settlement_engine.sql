set app.allow_ledger_ddl = '1';

-- Function to match Order Invoice <-> Payment in Settlement Engine
create or replace function public.match_order_payment_to_invoice(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice public.party_open_items%rowtype;
  v_pay public.party_open_items%rowtype;
  v_allocs jsonb := '[]'::jsonb;
  v_alloc_amt numeric;
  v_settlement_id uuid;
begin
  -- 1. Find the Invoice Item
  select * into v_invoice
  from public.party_open_items
  where source_table = 'orders'
    and source_id = p_order_id::text
    and item_type = 'invoice' -- Ensures we targeting the Invoice
    and status in ('open', 'partially_settled')
  limit 1;

  if not found then
    return; -- No open invoice found
  end if;

  -- 2. Find Unallocated Payments for this Order
  -- We look for Credit items linked to this order via the payments table
  for v_pay in
    select poi.*
    from public.party_open_items poi
    join public.payments p on p.id::text = poi.source_id
    where poi.source_table = 'payments'
      and p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
      and poi.status in ('open', 'partially_settled')
      and poi.direction = 'credit' -- Payments are credits
      and upper(poi.currency_code) = upper(v_invoice.currency_code) -- Strict Currency Match for now
    order by poi.occurred_at asc
  loop
    -- Calculate allocation amount (Lesser of Invoice Remaining vs Payment Remaining)
    -- We settle in FOREIGN currency if available and matching
    
    if v_invoice.open_foreign_amount is not null and v_pay.open_foreign_amount is not null then
       v_alloc_amt := least(v_invoice.open_foreign_amount, v_pay.open_foreign_amount);
       if v_alloc_amt > 1e-6 then
         v_allocs := v_allocs || jsonb_build_object(
           'fromOpenItemId', v_invoice.id, -- Debit (Invoice)
           'toOpenItemId', v_pay.id,       -- Credit (Payment)
           'allocatedForeignAmount', v_alloc_amt
         );
         -- Update memory state for next loop iteration
         v_invoice.open_foreign_amount := v_invoice.open_foreign_amount - v_alloc_amt;
       end if;
    else
       -- Base Currency Fallback
       v_alloc_amt := least(v_invoice.open_base_amount, v_pay.open_base_amount);
       if v_alloc_amt > 1e-6 then
         v_allocs := v_allocs || jsonb_build_object(
           'fromOpenItemId', v_invoice.id,
           'toOpenItemId', v_pay.id,
           'allocatedBaseAmount', v_alloc_amt
         );
         v_invoice.open_base_amount := v_invoice.open_base_amount - v_alloc_amt;
       end if;
    end if;

    if v_invoice.open_base_amount <= 1e-6 and (v_invoice.open_foreign_amount is null or v_invoice.open_foreign_amount <= 1e-6) then
      exit; -- Invoice fully paid
    end if;
  end loop;

  -- 3. Execute Settlement if we have allocations
  if jsonb_array_length(v_allocs) > 0 then
    perform public.create_settlement(
      v_invoice.party_id,
      now(),
      v_allocs,
      'Auto-Settlement for Order ' || p_order_id::text
    );
  end if;

exception when others then
  -- Log error but don't fail transaction?
  -- For debugging, raising notice might be better.
  raise notice 'Auto-Settlement failed for order %: %', p_order_id, SQLERRM;
end;
$$;

-- Trigger Function to detect new Open Items and trigger matching
create or replace function public.trg_auto_settle_cod_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref_id text;
  v_ref_table text;
begin
  -- Case 1: New Invoice (Order) Inserted
  if new.source_table = 'orders' and new.item_type = 'invoice' then
    perform public.match_order_payment_to_invoice(new.source_id::uuid);
  end if;

  -- Case 2: New Payment Inserted
  if new.source_table = 'payments' then
    -- Check if this payment is for an Order
    select reference_id, reference_table 
    into v_ref_id, v_ref_table
    from public.payments
    where id::text = new.source_id;

    if v_ref_table = 'orders' and v_ref_id is not null then
      perform public.match_order_payment_to_invoice(v_ref_id::uuid);
    end if;
  end if;

  return null;
end;
$$;

-- Register Trigger
drop trigger if exists trg_auto_settle_cod on public.party_open_items;
create trigger trg_auto_settle_cod
after insert on public.party_open_items
for each row execute function public.trg_auto_settle_cod_fn();

notify pgrst, 'reload schema';
