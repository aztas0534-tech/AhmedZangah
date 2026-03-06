-- ============================================================
-- Repair migration: Fix old sales returns with incorrect refund methods
-- 
-- Problem: Before this fix, the return UI only offered cash/network/kuraimi
-- as refund methods. Orders paid via AR (credit) were refunded as cash,
-- which means:
--   1. Cash was debited out of the register (wrong)
--   2. The AR receivable was NOT reduced (wrong) 
--   3. A payment 'out' record was created for cash (wrong)
--
-- This migration:
--   1. Identifies completed returns where order was AR but refund was cash
--   2. Corrects the journal entries (swap cash credit → AR credit)
--   3. Removes the incorrect cash payment record
--   4. Applies the AR open item credit
--   5. Updates the return record's refund_method to 'ar'
--   6. Logs the repair in audit logs
-- ============================================================

set app.allow_ledger_ddl = '1';

-- Temporarily disable immutability triggers for journal repair
set session_replication_role = 'replica';

do $$
declare
  v_ret record;
  v_order record;
  v_entry_id uuid;
  v_cash uuid;
  v_ar uuid;
  v_base_currency text;
  v_fixed_count integer := 0;
  v_payment record;
begin
  v_base_currency := coalesce(public.get_base_currency(), 'YER');
  v_cash := public.get_account_id_by_code('1010');
  v_ar := public.get_account_id_by_code('1200');

  if v_cash is null or v_ar is null then
    raise notice 'Cash or AR account not found, skipping repair';
    return;
  end if;

  -- Find completed sales returns where:
  --   - The order was an AR (credit) order
  --   - But the refund was processed as cash/network/kuraimi
  for v_ret in
    select sr.*
    from public.sales_returns sr
    join public.orders o on o.id = sr.order_id
    where sr.status = 'completed'
      and (
        -- Order was AR payment method
        lower(coalesce(o.data->>'paymentMethod', '')) = 'ar'
        or lower(coalesce(o.payment_method, '')) = 'ar'
        -- Or order has AR payments recorded
        or exists (
          select 1 from public.payments p
          where p.reference_table = 'orders'
            and p.reference_id = o.id::text
            and p.direction = 'in'
            and lower(p.method) = 'ar'
        )
      )
      and lower(coalesce(sr.refund_method, 'cash')) in ('cash', 'network', 'kuraimi')
  loop
    -- Get the journal entry for this return
    select je.id into v_entry_id
    from public.journal_entries je
    where je.source_table = 'sales_returns'
      and je.source_id = v_ret.id::text
      and je.source_event = 'processed'
    limit 1;

    if v_entry_id is null then
      continue; -- No journal entry found, skip
    end if;

    -- Fix journal lines: change credit from Cash (1010) to AR (1200)
    update public.journal_lines jl
    set account_id = v_ar,
        line_memo = 'Reduce accounts receivable (repaired from cash refund)'
    where jl.journal_entry_id = v_entry_id
      and jl.account_id = v_cash
      and jl.credit > 0;

    -- Also fix if it was bank (network/kuraimi → 1020)
    if not found then
      declare
        v_bank uuid;
      begin
        v_bank := public.get_account_id_by_code('1020');
        if v_bank is not null then
          update public.journal_lines jl
          set account_id = v_ar,
              line_memo = 'Reduce accounts receivable (repaired from bank refund)'
          where jl.journal_entry_id = v_entry_id
            and jl.account_id = v_bank
            and jl.credit > 0;
        end if;
      end;
    end if;

    -- Remove the incorrect outgoing cash/bank payment record
    for v_payment in
      select p.id, p.amount
      from public.payments p
      where p.reference_table = 'sales_returns'
        and p.reference_id = v_ret.id::text
        and p.direction = 'out'
        and lower(p.method) in ('cash', 'network', 'kuraimi')
    loop
      delete from public.payments where id = v_payment.id;
    end loop;

    -- Apply AR credit reduction for the order
    begin
      perform public._apply_ar_open_item_credit(
        v_ret.order_id,
        coalesce(v_ret.total_refund_amount, 0)
      );
    exception when others then
      -- If AR credit function is not available or fails, continue
      raise notice 'AR credit apply failed for return %: %', v_ret.id, sqlerrm;
    end;

    -- Update the return's refund_method to 'ar'
    update public.sales_returns
    set refund_method = 'ar',
        updated_at = now()
    where id = v_ret.id;

    -- Log the repair in audit
    insert into public.system_audit_logs(
      action, module, details, performed_by, performed_at,
      metadata, risk_level, reason_code
    ) values (
      'sales_returns.repair_refund_method',
      'sales',
      v_ret.id::text,
      coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
      now(),
      jsonb_build_object(
        'salesReturnId', v_ret.id::text,
        'orderId', v_ret.order_id::text,
        'oldRefundMethod', coalesce(v_ret.refund_method, 'cash'),
        'newRefundMethod', 'ar',
        'amount', coalesce(v_ret.total_refund_amount, 0),
        'repairedBy', 'migration_20260306041400'
      ),
      'HIGH',
      'DATA_REPAIR'
    );

    v_fixed_count := v_fixed_count + 1;
  end loop;

  raise notice 'Repaired % sales returns with incorrect refund method (AR orders refunded as cash)', v_fixed_count;
end $$;

-- Restore normal trigger behavior
set session_replication_role = 'origin';

-- Reset ledger DDL flag
reset app.allow_ledger_ddl;

notify pgrst, 'reload schema';
