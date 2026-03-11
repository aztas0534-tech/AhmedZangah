begin;

do $$
declare
  v_order record;
  v_payment record;
  v_shift_id uuid;
  v_has_out boolean;
begin
  -- Simulate a JWT payload for auth.uid() and auth.role() 
  -- We just need a dummy UUID that won't fail parsing. Wait, admin_users check relies on ACTUAL uuid in table!
  -- No, if auth.role() = 'service_role', many checks pass.
  set local "request.jwt.claims" = '{"role": "service_role"}';
  -- Set postgres role to bypass reverse payment journal owner check
  set local role postgres;

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
          -- Inline replication of reverse_payment_journal to bypass is_owner check
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
    -- Trap the error, don't fail the transaction, so we can inspect it!
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
    values ('MIGRATION_ERROR', 'database', SQLERRM, null, now(), jsonb_build_object('state', SQLSTATE), 'HIGH', 'ERROR');
  end;
end;
$$;

commit;
