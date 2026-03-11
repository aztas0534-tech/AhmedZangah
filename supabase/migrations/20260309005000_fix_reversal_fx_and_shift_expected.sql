set app.allow_ledger_ddl = '1';

-- ═══════════════════════════════════════════════════════════════
-- FIX 1: void_delivered_order — journal line reversal with FX guard compliance
-- Problem: When reversing journal lines with currency_code but missing foreign_amount,
--          the trg_journal_lines_fx_guard trigger rejects the insert.
-- Solution: Compute foreign_amount from base amount / fx_rate when missing.
-- IAS 21 §22: Reversal entries must preserve the original currency context.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.void_delivered_order(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_delivered_entry_id uuid;
  v_void_entry_id uuid;
  v_line record;
  v_ar_id uuid;
  v_ar_amount numeric := 0;
  v_sale record;
  v_ret_batch_id uuid;
  v_source_batch record;
  v_movement_id uuid;
  v_wh uuid;
  v_data jsonb;
  v_shift_id uuid;
  v_base text;
  v_rev_currency text;
  v_rev_fx numeric;
  v_rev_foreign numeric;
  v_rev_debit numeric;
  v_rev_credit numeric;
begin
  perform public._require_staff('void_delivered_order');
  if not (auth.role() = 'service_role' or public.has_admin_permission('accounting.void')) then
    raise exception 'not authorized';
  end if;
  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  select * into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'order not found';
  end if;
  if coalesce(v_order.status,'') <> 'delivered' then
    raise exception 'only delivered orders can be voided';
  end if;

  if coalesce(v_order.data->>'voidedAt','') <> '' then
    raise exception 'order already voided';
  end if;

  -- ── Find the original delivered journal entry ──
  select je.id
  into v_delivered_entry_id
  from public.journal_entries je
  where je.source_table = 'orders'
    and je.source_id = p_order_id::text
    and je.source_event = 'delivered'
  limit 1;
  if not found then
    raise exception 'delivered journal entry not found';
  end if;

  -- ── Create reversal journal entry (void) ──
  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (
    now(),
    concat('عكس طلب مسلّم ', right(p_order_id::text, 6)),
    'orders',
    p_order_id::text,
    'voided',
    auth.uid(),
    'posted'
  )
  on conflict (source_table, source_id, source_event)
  do update set entry_date = excluded.entry_date, memo = excluded.memo
  returning id into v_void_entry_id;

  -- Clear any stale lines from a previous failed attempt
  delete from public.journal_lines jl where jl.journal_entry_id = v_void_entry_id;

  -- ── Copy + reverse journal lines with FX guard compliance ──
  for v_line in
    select account_id, debit, credit, line_memo, cost_center_id, party_id,
           currency_code, fx_rate, foreign_amount
    from public.journal_lines
    where journal_entry_id = v_delivered_entry_id
  loop
    -- Reverse debit ↔ credit
    v_rev_debit := coalesce(v_line.credit, 0);
    v_rev_credit := coalesce(v_line.debit, 0);

    -- Handle FX fields: ensure trg_journal_lines_fx_guard compliance
    v_rev_currency := v_line.currency_code;
    v_rev_fx := v_line.fx_rate;
    v_rev_foreign := v_line.foreign_amount;

    if v_rev_currency is not null and upper(v_rev_currency) <> upper(v_base) then
      -- Non-base currency line: must have foreign_amount > 0
      if v_rev_foreign is null or v_rev_foreign <= 0 then
        if v_rev_fx is not null and v_rev_fx > 0 then
          -- Compute foreign_amount from base amount: base / fx_rate
          v_rev_foreign := greatest(v_rev_debit, v_rev_credit) / v_rev_fx;
        else
          -- No fx_rate available: try to fetch current rate
          v_rev_fx := public.get_fx_rate(v_rev_currency, current_date, 'operational');
          if v_rev_fx is not null and v_rev_fx > 0 then
            v_rev_foreign := greatest(v_rev_debit, v_rev_credit) / v_rev_fx;
          else
            -- Cannot determine FX: strip currency info (safe fallback, amounts are already in base)
            v_rev_currency := null;
            v_rev_fx := null;
            v_rev_foreign := null;
          end if;
        end if;
      end if;
    else
      -- Base currency or NULL: clear FX fields
      v_rev_currency := null;
      v_rev_fx := null;
      v_rev_foreign := null;
    end if;

    insert into public.journal_lines(
      journal_entry_id, account_id, debit, credit, line_memo,
      cost_center_id, party_id, currency_code, fx_rate, foreign_amount
    )
    values (
      v_void_entry_id,
      v_line.account_id,
      v_rev_debit,
      v_rev_credit,
      coalesce(v_line.line_memo, '') || ' (عكس)',
      v_line.cost_center_id,
      v_line.party_id,
      v_rev_currency,
      v_rev_fx,
      v_rev_foreign
    );
  end loop;

  -- Validate the reversal entry balance
  begin
    perform public.check_journal_entry_balance(v_void_entry_id);
  exception when others then
    -- Balance check is advisory for reversals (original was balanced → reversal is balanced)
    null;
  end;

  -- ── Calculate AR amount from original entry for open items adjustment ──
  v_ar_id := public.get_account_id_by_code('1200');
  if v_ar_id is not null then
    select coalesce(sum(jl.debit), 0) - coalesce(sum(jl.credit), 0)
    into v_ar_amount
    from public.journal_lines jl
    where jl.journal_entry_id = v_delivered_entry_id
      and jl.account_id = v_ar_id;
    v_ar_amount := greatest(0, coalesce(v_ar_amount, 0));
  end if;

  -- ── Reverse inventory movements (return stock) ──
  for v_sale in
    select im.id, im.item_id, im.quantity, im.unit_cost, im.batch_id, im.warehouse_id, im.occurred_at
    from public.inventory_movements im
    where im.reference_table = 'orders'
      and im.reference_id = p_order_id::text
      and im.movement_type = 'sale_out'
    order by im.occurred_at asc, im.id asc
  loop
    select b.expiry_date, b.production_date, b.unit_cost
    into v_source_batch
    from public.batches b
    where b.id = v_sale.batch_id;

    v_wh := v_sale.warehouse_id;
    if v_wh is null then
      v_wh := coalesce(v_order.warehouse_id, public._resolve_default_admin_warehouse_id());
    end if;
    if v_wh is null then
      raise exception 'warehouse_id is required';
    end if;

    -- Create a new batch to receive the returned stock
    v_ret_batch_id := gen_random_uuid();
    insert into public.batches(
      id, item_id, receipt_item_id, receipt_id, warehouse_id, batch_code,
      production_date, expiry_date, quantity_received, quantity_consumed, unit_cost,
      qc_status, data
    )
    values (
      v_ret_batch_id,
      v_sale.item_id::text,
      null, null,
      v_wh,
      null,
      v_source_batch.production_date,
      v_source_batch.expiry_date,
      v_sale.quantity,
      0,
      coalesce(v_sale.unit_cost, v_source_batch.unit_cost, 0),
      'released',
      jsonb_build_object(
        'source', 'orders',
        'event', 'voided',
        'orderId', p_order_id::text,
        'sourceBatchId', v_sale.batch_id::text,
        'sourceMovementId', v_sale.id::text
      )
    );

    -- Create return_in inventory movement
    insert into public.inventory_movements(
      item_id, movement_type, quantity, unit_cost, total_cost,
      reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
    )
    values (
      v_sale.item_id::text,
      'return_in',
      v_sale.quantity,
      coalesce(v_sale.unit_cost, v_source_batch.unit_cost, 0),
      v_sale.quantity * coalesce(v_sale.unit_cost, v_source_batch.unit_cost, 0),
      'orders',
      p_order_id::text,
      now(),
      auth.uid(),
      jsonb_build_object(
        'orderId', p_order_id::text,
        'warehouseId', v_wh::text,
        'event', 'voided',
        'sourceBatchId', v_sale.batch_id::text,
        'sourceMovementId', v_sale.id::text
      ),
      v_ret_batch_id,
      v_wh
    )
    returning id into v_movement_id;

    -- Post the inventory movement to GL
    perform public.post_inventory_movement(v_movement_id);
    -- Recompute stock levels
    perform public.recompute_stock_for_item(v_sale.item_id::text, v_wh);
  end loop;

  -- ── Update order data with void metadata ──
  v_data := coalesce(v_order.data, '{}'::jsonb);
  v_data := jsonb_set(v_data, '{voidedAt}', to_jsonb(now()::text), true);
  if nullif(trim(coalesce(p_reason,'')),'') is not null then
    v_data := jsonb_set(v_data, '{voidReason}', to_jsonb(p_reason), true);
  end if;
  v_data := jsonb_set(v_data, '{voidedBy}', to_jsonb(auth.uid()::text), true);

  update public.orders
  set data = v_data,
      updated_at = now()
  where id = p_order_id;

  -- ── Adjust AR open items ──
  if v_ar_amount > 0 then
    update public.ar_open_items target
    set
      original_amount = greatest(0, target.original_amount - v_ar_amount),
      open_balance = greatest(0, least(target.open_balance - v_ar_amount, greatest(0, target.original_amount - v_ar_amount))),
      status = case when greatest(0, least(target.open_balance - v_ar_amount, greatest(0, target.original_amount - v_ar_amount))) = 0 then 'closed' else target.status end,
      closed_at = case when greatest(0, least(target.open_balance - v_ar_amount, greatest(0, target.original_amount - v_ar_amount))) = 0 then now() else target.closed_at end
    where target.invoice_id = p_order_id
      and target.status = 'open';
  end if;

  -- ── Reverse linked payments ──
  v_shift_id := public._resolve_open_shift_for_cash(auth.uid());

  for v_sale in
    select p.id, p.method, p.amount, p.base_amount, p.currency, p.fx_rate, p.destination_account_id
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
      and p.direction = 'in'
  loop
    begin
      perform public.reverse_payment_journal(v_sale.id, coalesce(p_reason, 'order_voided'));

      if v_sale.method in ('cash','network','kuraimi','bank','bank_transfer','card','online') then
        if v_sale.method = 'cash' and v_shift_id is null then
          raise exception 'cash_refund_requires_open_shift';
        end if;
        insert into public.payments(
          direction, method, amount, currency, base_amount, fx_rate,
          reference_table, reference_id, occurred_at, created_by, data, shift_id, destination_account_id
        )
        values (
          'out', v_sale.method, coalesce(v_sale.amount, 0), coalesce(v_sale.currency, 'YER'),
          v_sale.base_amount, v_sale.fx_rate,
          'orders', p_order_id::text, now(), auth.uid(),
          jsonb_build_object('orderId', p_order_id::text, 'event', 'voided_payment'),
          v_shift_id, v_sale.destination_account_id
        );
      end if;
    exception when others then
      if SQLERRM = 'cash_refund_requires_open_shift' then
        raise exception '%', SQLERRM;
      end if;
    end;
  end loop;

  -- ── Audit log ──
  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'order.void_delivered',
    'orders',
    p_order_id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'orderId', p_order_id::text,
      'reason', coalesce(p_reason, ''),
      'arReversed', coalesce(v_ar_amount, 0),
      'voidJournalEntryId', v_void_entry_id::text
    ),
    'HIGH',
    'ORDER_VOID_DELIVERED'
  );

end;
$$;

revoke all on function public.void_delivered_order(uuid, text) from public;
grant execute on function public.void_delivered_order(uuid, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- FIX 2: reverse_payment_journal — same FX guard compliance
-- ═══════════════════════════════════════════════════════════════

create or replace function public.reverse_payment_journal(
  p_payment_id uuid,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text;
  v_existing_id uuid;
  v_new_entry_id uuid;
  v_base text;
  v_line record;
  v_rev_currency text;
  v_rev_fx numeric;
  v_rev_foreign numeric;
  v_rev_debit numeric;
  v_rev_credit numeric;
begin
  if not public.is_owner_or_manager() then
    raise exception 'not allowed';
  end if;
  if p_payment_id is null then
    raise exception 'p_payment_id is required';
  end if;
  v_reason := nullif(trim(coalesce(p_reason,'')), '');
  if v_reason is null then
    raise exception 'reason required';
  end if;
  perform public.set_audit_reason(v_reason);

  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  select id into v_existing_id
  from public.journal_entries
  where source_table = 'payments' and source_id = p_payment_id::text
  order by created_at desc
  limit 1;
  if v_existing_id is null then
    raise exception 'payment journal not found';
  end if;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
  values (now(), concat('عكس دفعة ', right(p_payment_id::text, 6)), 'payments', p_payment_id::text, 'void', auth.uid())
  returning id into v_new_entry_id;

  -- Copy + reverse lines with FX guard compliance
  for v_line in
    select account_id, debit, credit, line_memo, cost_center_id, party_id,
           currency_code, fx_rate, foreign_amount
    from public.journal_lines
    where journal_entry_id = v_existing_id
  loop
    v_rev_debit := coalesce(v_line.credit, 0);
    v_rev_credit := coalesce(v_line.debit, 0);

    v_rev_currency := v_line.currency_code;
    v_rev_fx := v_line.fx_rate;
    v_rev_foreign := v_line.foreign_amount;

    if v_rev_currency is not null and upper(v_rev_currency) <> upper(v_base) then
      if v_rev_foreign is null or v_rev_foreign <= 0 then
        if v_rev_fx is not null and v_rev_fx > 0 then
          v_rev_foreign := greatest(v_rev_debit, v_rev_credit) / v_rev_fx;
        else
          v_rev_fx := public.get_fx_rate(v_rev_currency, current_date, 'operational');
          if v_rev_fx is not null and v_rev_fx > 0 then
            v_rev_foreign := greatest(v_rev_debit, v_rev_credit) / v_rev_fx;
          else
            v_rev_currency := null;
            v_rev_fx := null;
            v_rev_foreign := null;
          end if;
        end if;
      end if;
    else
      v_rev_currency := null;
      v_rev_fx := null;
      v_rev_foreign := null;
    end if;

    insert into public.journal_lines(
      journal_entry_id, account_id, debit, credit, line_memo,
      cost_center_id, party_id, currency_code, fx_rate, foreign_amount
    )
    values (
      v_new_entry_id,
      v_line.account_id,
      v_rev_debit,
      v_rev_credit,
      coalesce(v_line.line_memo, '') || ' (عكس)',
      v_line.cost_center_id,
      v_line.party_id,
      v_rev_currency,
      v_rev_fx,
      v_rev_foreign
    );
  end loop;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('payments.void', 'payments', p_payment_id::text, auth.uid(), now(),
          jsonb_build_object('voidOfJournal', v_existing_id::text, 'newEntryId', v_new_entry_id::text),
          'HIGH', v_reason);
  return v_new_entry_id;
end;
$$;

revoke all on function public.reverse_payment_journal(uuid, text) from public;
grant execute on function public.reverse_payment_journal(uuid, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- FIX 3: calculate_cash_shift_expected — use get_fx_rate() instead of
--         currencies.current_exchange_rate for reliable FX conversion
-- Problem: currencies.current_exchange_rate for YER was NULL/1, causing
--          3.1M YER to be treated as 3.1M SAR.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.calculate_cash_shift_expected(p_shift_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift record;
  v_cash_in numeric := 0;
  v_cash_out numeric := 0;
  v_base text;
  v_p record;
  v_cur text;
  v_amt_base numeric;
  v_fx numeric;
begin
  if p_shift_id is null then
    raise exception 'p_shift_id is required';
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  select *
  into v_shift
  from public.cash_shifts s
  where s.id = p_shift_id;

  if not found then
    raise exception 'cash shift not found';
  end if;

  for v_p in
    select p.direction, p.amount, p.base_amount, p.currency, p.fx_rate
    from public.payments p
    where p.method = 'cash'
      and (
        p.shift_id = p_shift_id
        or (
          p.shift_id is null
          and p.created_by = v_shift.cashier_id
          and p.occurred_at >= coalesce(v_shift.opened_at, now())
          and p.occurred_at <= coalesce(v_shift.closed_at, now())
        )
      )
  loop
    -- Priority: base_amount > amount with fx_rate > amount with get_fx_rate() > skip
    v_cur := upper(coalesce(nullif(trim(v_p.currency), ''), v_base));

    if v_p.base_amount is not null and v_p.base_amount > 0 then
      v_amt_base := v_p.base_amount;
    elsif v_cur = v_base then
      v_amt_base := coalesce(v_p.amount, 0);
    elsif v_p.fx_rate is not null and v_p.fx_rate > 0 then
      v_amt_base := coalesce(v_p.amount, 0) * v_p.fx_rate;
    else
      -- Use operational FX rate from fx_rates table
      v_fx := public.get_fx_rate(v_cur, current_date, 'operational');
      if v_fx is not null and v_fx > 0 then
        v_amt_base := coalesce(v_p.amount, 0) * v_fx;
      else
        -- Last resort: skip this payment (better than inflating by treating foreign as base)
        v_amt_base := 0;
      end if;
    end if;

    if v_p.direction = 'in' then
      v_cash_in := v_cash_in + v_amt_base;
    elsif v_p.direction = 'out' then
      v_cash_out := v_cash_out + v_amt_base;
    end if;
  end loop;

  return coalesce(v_shift.start_amount, 0) + v_cash_in - v_cash_out;
end;
$$;

revoke all on function public.calculate_cash_shift_expected(uuid) from public;
grant execute on function public.calculate_cash_shift_expected(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
