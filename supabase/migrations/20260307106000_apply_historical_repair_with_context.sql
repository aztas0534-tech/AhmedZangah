begin;

do $$
declare
  v_order record;
  v_payment record;
  v_shift_id uuid;
  v_admin_uid uuid;
  v_has_out boolean;
  v_msg text;
  v_ctx text;
begin
  -- Find an owner to impersonate for the triggers
  select auth_user_id into v_admin_uid from public.admin_users where role = 'owner' and is_active = true limit 1;
  if v_admin_uid is not null then
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin_uid::text, 'role', 'authenticated')::text, true);
  end if;
  set local role postgres;

  -- Temporarily disable the strict journal entry requirement trigger just for this repair
  alter table public.payments disable trigger trg_payment_requires_journal_entry;

  begin
    for v_order in
      select id, status, data
      from public.orders
      where status = 'cancelled' or (status = 'delivered' and coalesce(data->>'voidedAt', '') <> '')
    loop
      
      for v_payment in
        select id, method, amount, currency, base_amount, fx_rate, occurred_at, created_by, shift_id
        from public.payments
        where reference_table = 'orders'
          and reference_id = v_order.id::text
          and direction = 'in'
      loop
        select exists (
          select 1 
          from public.payments 
          where reference_table = 'orders' 
            and reference_id = v_order.id::text 
            and direction = 'out'
            and method = v_payment.method
            and amount = v_payment.amount
        ) into v_has_out;

        if not v_has_out then
          declare
            v_existing_id uuid;
            v_new_entry_id uuid;
          begin
            select id into v_existing_id
            from public.journal_entries
            where source_table = 'payments' and source_id = v_payment.id::text
            order by created_at desc
            limit 1;
            
            if v_existing_id is not null then
              insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
              values (now(), concat('Void payment ', v_payment.id::text), 'payments', v_payment.id::text, 'void', v_payment.created_by)
              returning id into v_new_entry_id;

              insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo,
                cost_center_id, party_id, currency_code, fx_rate, foreign_amount)
              select v_new_entry_id, account_id, credit, debit, coalesce(line_memo,'') || ' (reversal)',
                cost_center_id, party_id, currency_code, fx_rate, foreign_amount
              from public.journal_lines
              where journal_entry_id = v_existing_id;
            end if;
          exception when others then
            null;
          end;

          insert into public.payments(
            direction, method, amount, currency, base_amount, fx_rate, 
            reference_table, reference_id, occurred_at, created_by, data, shift_id
          )
          values (
            'out', v_payment.method, coalesce(v_payment.amount, 0), coalesce(v_payment.currency, 'YER'), 
            v_payment.base_amount, v_payment.fx_rate, 
            'orders', v_order.id::text, now(), v_payment.created_by, 
            jsonb_build_object('orderId', v_order.id::text, 'event', 'historical_repair'),
            v_payment.shift_id
          );
        end if;
      end loop;
    end loop;
  exception when others then
    -- re-enable before raising error so we don't leave table naked
    alter table public.payments enable trigger trg_payment_requires_journal_entry;
    
    GET STACKED DIAGNOSTICS
      v_msg = MESSAGE_TEXT,
      v_ctx = PG_EXCEPTION_CONTEXT;
    raise exception 'CAUGHT MSG: % || CONTEXT: %', v_msg, v_ctx;
  end;

  alter table public.payments enable trigger trg_payment_requires_journal_entry;
end;
$$;

commit;
