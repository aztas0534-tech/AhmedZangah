-- Diagnostic for payments linked to INV-001272 (025DDD19)
do $$
declare
  v_order_id text := '025ddd19';
  v_full_id uuid;
begin
  select id into v_full_id from public.orders where right(id::text, 8) = v_order_id limit 1;
  raise notice 'Order ID: %', v_full_id;

  -- Check payments linked to this order
  declare
    v_rec record;
    v_total numeric := 0;
  begin
    for v_rec in
      select id, amount, base_amount, currency, direction, reference_table, reference_id
      from public.payments
      where reference_id = v_full_id::text
    loop
      raise notice 'Payment: % | Amt: % % | Base: % | Dir: % | Ref: %',
        v_rec.id, v_rec.amount, v_rec.currency, v_rec.base_amount, v_rec.direction, v_rec.reference_id;
      if v_rec.direction = 'in' then
        v_total := v_total + coalesce(v_rec.base_amount, 0);
      end if;
    end loop;
    raise notice 'Total base deposits paid found: %', v_total;
  end;

  -- Check what post_order_delivery calculated
  declare
    v_rec record;
  begin
    for v_rec in
      select je.id, je.memo, jl.account_id, psa.role, jl.debit, jl.credit, jl.foreign_amount, jl.currency_code
      from public.journal_entries je
      join public.journal_lines jl on jl.journal_entry_id = je.id
      left join public.party_subledger_accounts psa on psa.account_id = jl.account_id
      where je.source_table = 'orders' and je.source_id = v_full_id::text
    loop
      raise notice 'Post: % | % | Role: % | Dr: % | Cr: % | For: % %',
        v_rec.memo, v_rec.account_id, v_rec.role, v_rec.debit, v_rec.credit, v_rec.foreign_amount, v_rec.currency_code;
    end loop;
  end;
end $$;
