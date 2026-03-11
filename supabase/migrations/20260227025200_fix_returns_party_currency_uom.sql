set app.allow_ledger_ddl = '1';

-- ============================================================================
-- FIX 1 + 2: process_sales_return — add party_id on AR journal lines
--            and call ensure_party_currency for multi-currency tracking
-- ============================================================================
create or replace function public.process_sales_return(p_return_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ret record;
  v_order record;
  v_entry_id uuid;
  v_cash uuid;
  v_bank uuid;
  v_ar uuid;
  v_deposits uuid;
  v_sales_returns uuid;
  v_vat_payable uuid;
  v_base_currency text;
  v_fx numeric;
  v_order_subtotal numeric;
  v_order_discount numeric;
  v_order_net_subtotal numeric;
  v_order_tax numeric;
  v_return_subtotal numeric;
  v_tax_refund numeric;
  v_total_refund numeric;
  v_base_return_subtotal numeric;
  v_base_tax_refund numeric;
  v_base_total_refund numeric;
  v_currency text;
  v_refund_method text;
  v_shift_id uuid;
  v_item jsonb;
  v_item_id text;
  v_qty numeric;
  v_needed numeric;
  v_sale record;
  v_already numeric;
  v_free numeric;
  v_alloc numeric;
  v_ret_batch_id uuid;
  v_source_batch record;
  v_movement_id uuid;
  v_wh uuid;
  v_ar_reduction numeric := 0;
  v_paid_total numeric := 0;
  v_prev_refunded_total numeric := 0;
  -- NEW: party tracking
  v_customer_party_id uuid := null;
  v_fx_code_for_line text;
  v_fx_rate_for_line numeric;
  v_foreign_for_line numeric;
begin
  perform public._require_staff('process_sales_return');
  if not (
    auth.role() = 'service_role'
    or public.has_admin_permission('accounting.manage')
    or public.can_manage_orders()
  ) then
    raise exception 'not authorized';
  end if;

  if p_return_id is null then
    raise exception 'p_return_id is required';
  end if;

  select *
  into v_ret
  from public.sales_returns r
  where r.id = p_return_id
  for update;
  if not found then
    raise exception 'sales return not found';
  end if;
  if v_ret.status = 'completed' then
    return;
  end if;
  if v_ret.status = 'cancelled' then
    raise exception 'sales return is cancelled';
  end if;

  select *
  into v_order
  from public.orders o
  where o.id = v_ret.order_id;
  if not found then
    raise exception 'order not found';
  end if;
  if coalesce(v_order.status,'') <> 'delivered' then
    raise exception 'sales return requires delivered order';
  end if;
  if nullif(trim(coalesce(v_order.data->>'voidedAt','')), '') is not null then
    raise exception 'order already voided';
  end if;

  v_cash := public.get_account_id_by_code('1010');
  v_bank := public.get_account_id_by_code('1020');
  v_ar := public.get_account_id_by_code('1200');
  v_deposits := public.get_account_id_by_code('2050');
  v_sales_returns := public.get_account_id_by_code('4026');
  v_vat_payable := public.get_account_id_by_code('2020');

  v_base_currency := upper(coalesce(public.get_base_currency(), 'YER'));
  v_currency := upper(coalesce(
    nullif(btrim(coalesce(v_order.currency, '')), ''),
    nullif(btrim(coalesce(v_order.data->>'currency', '')), ''),
    v_base_currency
  ));
  v_fx := coalesce(nullif(v_order.fx_rate, 0), 0);
  begin
    v_fx := coalesce(v_fx, nullif((v_order.data->>'fxRate')::numeric, 0), 0);
  exception when others then
  end;
  if upper(v_currency) = upper(v_base_currency) then
    v_fx := 1;
  elsif coalesce(v_fx, 0) <= 0 then
    v_fx := coalesce(nullif(public.get_fx_rate(v_currency, coalesce(v_ret.return_date, now())::date, 'operational'), 0), 0);
  end if;
  if upper(v_currency) <> upper(v_base_currency) and coalesce(v_fx, 0) <= 0 then
    raise exception 'fx_rate missing for currency %', v_currency;
  end if;

  -- FIX 1: resolve customer party_id
  begin
    if v_order.customer_auth_user_id is not null then
      v_customer_party_id := public.ensure_financial_party_for_customer(v_order.customer_auth_user_id);
    end if;
  exception when others then
    v_customer_party_id := null;
  end;

  -- FIX 2: register currency for party
  if v_customer_party_id is not null and upper(v_currency) <> upper(v_base_currency) then
    begin
      perform public.ensure_party_currency(v_customer_party_id, v_currency);
    exception when others then null;
    end;
  end if;

  -- Pre-compute FX fields for journal lines
  if upper(v_currency) = upper(v_base_currency) then
    v_fx_code_for_line := null;
    v_fx_rate_for_line := null;
  else
    v_fx_code_for_line := v_currency;
    v_fx_rate_for_line := v_fx;
  end if;

  v_order_subtotal := coalesce(nullif((v_order.data->>'subtotal')::numeric, null), coalesce(v_order.subtotal, 0), 0);
  v_order_discount := coalesce(nullif((v_order.data->>'discountAmount')::numeric, null), coalesce(v_order.discount, 0), 0);
  v_order_net_subtotal := greatest(0, v_order_subtotal - v_order_discount);
  v_order_tax := coalesce(nullif((v_order.data->>'taxAmount')::numeric, null), coalesce(v_order.tax_amount, 0), 0);

  v_return_subtotal := coalesce(nullif(v_ret.total_refund_amount, null), 0);
  v_order_net_subtotal := public._money_round(v_order_net_subtotal, v_currency);
  v_order_tax := public._money_round(v_order_tax, v_currency);
  v_return_subtotal := public._money_round(v_return_subtotal, v_currency);
  if v_return_subtotal <= 0 then
    raise exception 'invalid return amount';
  end if;
  if v_return_subtotal > (v_order_net_subtotal + 0.000000001) then
    raise exception 'return amount exceeds order net subtotal';
  end if;

  v_tax_refund := 0;
  if v_order_net_subtotal > 0 and v_order_tax > 0 then
    v_tax_refund := least(v_order_tax, (v_return_subtotal / v_order_net_subtotal) * v_order_tax);
  end if;
  v_tax_refund := public._money_round(v_tax_refund, v_currency);
  v_total_refund := public._money_round(v_return_subtotal + v_tax_refund, v_currency);
  v_base_return_subtotal := public._money_round(v_return_subtotal * v_fx, v_base_currency);
  v_base_tax_refund := public._money_round(v_tax_refund * v_fx, v_base_currency);
  v_base_total_refund := public._money_round(v_total_refund * v_fx, v_base_currency);

  v_refund_method := coalesce(nullif(trim(coalesce(v_ret.refund_method, '')), ''), 'cash');
  if v_refund_method in ('bank', 'bank_transfer') then
    v_refund_method := 'kuraimi';
  elsif v_refund_method in ('card', 'online') then
    v_refund_method := 'network';
  end if;

  if to_regclass('public.payments') is not null then
    begin
      select coalesce(sum(p.amount), 0)
      into v_paid_total
      from public.payments p
      where p.direction = 'in'
        and p.reference_table = 'orders'
        and p.reference_id = v_order.id::text
        and upper(coalesce(p.currency, v_currency)) = upper(v_currency);
    exception when others then
      v_paid_total := 0;
    end;

    begin
      select coalesce(sum(p.amount), 0)
      into v_prev_refunded_total
      from public.payments p
      where p.direction = 'out'
        and p.reference_table = 'sales_returns'
        and (p.data->>'orderId') = v_order.id::text
        and upper(coalesce(p.currency, v_currency)) = upper(v_currency);
    exception when others then
      v_prev_refunded_total := 0;
    end;
  end if;

  v_paid_total := public._money_round(v_paid_total, v_currency);
  v_prev_refunded_total := public._money_round(v_prev_refunded_total, v_currency);

  if v_refund_method in ('cash','network','kuraimi') then
    if v_paid_total <= 0 then
      raise exception 'cash/bank refund requires a paid order';
    end if;
    if (v_prev_refunded_total + v_total_refund) > (v_paid_total + 0.000000001) then
      raise exception 'refund exceeds paid amount for this order';
    end if;
  end if;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (
    coalesce(v_ret.return_date, now()),
    concat('Sales return ', v_ret.id::text),
    'sales_returns',
    v_ret.id::text,
    'processed',
    auth.uid(),
    'posted'
  )
  on conflict (source_table, source_id, source_event)
  do update set entry_date = excluded.entry_date, memo = excluded.memo
  returning id into v_entry_id;

  delete from public.journal_lines jl where jl.journal_entry_id = v_entry_id;

  -- Sales Returns (debit)
  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
  values (
    v_entry_id,
    v_sales_returns,
    v_base_return_subtotal,
    0,
    'Sales return',
    v_fx_code_for_line,
    v_fx_rate_for_line,
    case when v_fx_code_for_line is not null then v_return_subtotal else null end
  );

  -- VAT reverse (debit)
  if v_tax_refund > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (
      v_entry_id,
      v_vat_payable,
      v_base_tax_refund,
      0,
      'Reverse VAT payable',
      v_fx_code_for_line,
      v_fx_rate_for_line,
      case when v_fx_code_for_line is not null then v_tax_refund else null end
    );
  end if;

  -- Credit line (refund destination) — with party_id on AR lines
  if v_refund_method = 'cash' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (v_entry_id, v_cash, 0, v_base_total_refund, 'Cash refund',
      v_fx_code_for_line, v_fx_rate_for_line,
      case when v_fx_code_for_line is not null then v_total_refund else null end);
  elsif v_refund_method in ('network','kuraimi') then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (v_entry_id, v_bank, 0, v_base_total_refund, 'Bank refund',
      v_fx_code_for_line, v_fx_rate_for_line,
      case when v_fx_code_for_line is not null then v_total_refund else null end);
  elsif v_refund_method = 'ar' then
    -- FIX 1: set party_id on AR credit line
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values (v_entry_id, v_ar, 0, v_base_total_refund, 'Reduce accounts receivable',
      v_fx_code_for_line, v_fx_rate_for_line,
      case when v_fx_code_for_line is not null then v_total_refund else null end,
      v_customer_party_id);
    v_ar_reduction := v_base_total_refund;
  elsif v_refund_method = 'store_credit' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values (v_entry_id, v_deposits, 0, v_base_total_refund, 'Increase customer deposit',
      v_fx_code_for_line, v_fx_rate_for_line,
      case when v_fx_code_for_line is not null then v_total_refund else null end,
      v_customer_party_id);
  else
    v_refund_method := 'cash';
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (v_entry_id, v_cash, 0, v_base_total_refund, 'Cash refund',
      v_fx_code_for_line, v_fx_rate_for_line,
      case when v_fx_code_for_line is not null then v_total_refund else null end);
  end if;

  -- Inventory return_in loop (batch-level FIFO)
  for v_item in select value from jsonb_array_elements(coalesce(v_ret.items, '[]'::jsonb))
  loop
    v_item_id := nullif(trim(coalesce(v_item->>'itemId', '')), '');
    begin
      v_qty := coalesce(
        nullif(v_item->>'qtyBase','')::numeric,
        nullif(v_item->>'qty_base','')::numeric,
        nullif(v_item->>'quantityBase','')::numeric,
        nullif(v_item->>'quantity_base','')::numeric,
        nullif(v_item->>'quantity','')::numeric,
        0
      );
    exception when others then
      v_qty := 0;
    end;
    if v_item_id is null or v_qty <= 0 then
      continue;
    end if;

    v_needed := v_qty;

    for v_sale in
      select im.id, im.item_id, im.quantity, im.unit_cost, im.total_cost, im.batch_id, im.warehouse_id, im.occurred_at
      from public.inventory_movements im
      where im.reference_table = 'orders'
        and im.reference_id = v_ret.order_id::text
        and im.movement_type = 'sale_out'
        and im.item_id::text = v_item_id::text
      order by im.occurred_at asc, im.id asc
    loop
      exit when v_needed <= 0;

      select coalesce(sum(imr.quantity), 0)
      into v_already
      from public.inventory_movements imr
      where imr.reference_table = 'sales_returns'
        and imr.movement_type = 'return_in'
        and (imr.data->>'orderId') = v_ret.order_id::text
        and (imr.data->>'sourceMovementId') = v_sale.id::text;

      v_free := greatest(coalesce(v_sale.quantity, 0) - coalesce(v_already, 0), 0);
      if v_free <= 0 then
        continue;
      end if;

      v_alloc := least(v_needed, v_free);
      if v_alloc <= 0 then
        continue;
      end if;

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

      v_ret_batch_id := gen_random_uuid();
      insert into public.batches(
        id, item_id, receipt_item_id, receipt_id, warehouse_id, batch_code,
        production_date, expiry_date, quantity_received, quantity_consumed,
        unit_cost, qc_status, data
      )
      values (
        v_ret_batch_id, v_item_id::text, null, null, v_wh, null,
        v_source_batch.production_date, v_source_batch.expiry_date,
        v_alloc, 0, coalesce(v_source_batch.unit_cost, 0), 'approved',
        jsonb_build_object('sourceBatchId', v_sale.batch_id::text, 'sourceMovementId', v_sale.id::text, 'sourceOrderId', v_ret.order_id::text)
      );

      insert into public.batch_balances(item_id, batch_id, warehouse_id, quantity, expiry_date)
      values (v_item_id::text, v_ret_batch_id, v_wh, v_alloc, v_source_batch.expiry_date)
      on conflict (item_id, batch_id, warehouse_id) do update set quantity = public.batch_balances.quantity + excluded.quantity;

      insert into public.inventory_movements(
        item_id, movement_type, quantity, unit_cost, total_cost,
        reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
      )
      values (
        v_item_id::text, 'return_in', v_alloc,
        coalesce(v_source_batch.unit_cost, 0),
        (v_alloc * coalesce(v_source_batch.unit_cost, 0)),
        'sales_returns', v_ret.id::text,
        coalesce(v_ret.return_date, now()), auth.uid(),
        jsonb_build_object(
          'orderId', v_ret.order_id::text,
          'sourceMovementId', v_sale.id::text,
          'currency', v_currency,
          'fxRate', v_fx
        ),
        v_ret_batch_id, v_wh
      )
      returning id into v_movement_id;

      perform public.post_inventory_movement(v_movement_id);
      perform public.recompute_stock_for_item(v_item_id::text, v_wh);

      v_needed := v_needed - v_alloc;
    end loop;

    if v_needed > 1e-9 then
      raise exception 'return exceeds sold quantity for item %', v_item_id;
    end if;
  end loop;

  update public.sales_returns
  set status = 'completed',
      updated_at = now()
  where id = p_return_id;

  v_shift_id := public._resolve_open_shift_for_cash(auth.uid());
  if v_refund_method = 'cash' and v_shift_id is null then
    raise exception 'cash refund requires an open cash shift';
  end if;

  if v_refund_method in ('cash','network','kuraimi') then
    insert into public.payments(direction, method, amount, currency, reference_table, reference_id, occurred_at, created_by, data, shift_id)
    values (
      'out',
      v_refund_method,
      v_total_refund,
      coalesce(v_order.data->>'currency', v_order.currency, 'YER'),
      'sales_returns',
      v_ret.id::text,
      coalesce(v_ret.return_date, now()),
      auth.uid(),
      jsonb_build_object('orderId', v_ret.order_id::text),
      v_shift_id
    );
  end if;

  if v_ar_reduction > 0 then
    perform public._apply_ar_open_item_credit(v_ret.order_id, v_ar_reduction);
  end if;

  perform public.recompute_order_return_status(v_ret.order_id);

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'sales_returns.process',
    'sales',
    v_ret.id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'salesReturnId', v_ret.id::text,
      'orderId', v_ret.order_id::text,
      'refundMethod', v_refund_method,
      'amount', v_total_refund,
      'currency', v_currency,
      'partyId', v_customer_party_id::text
    ),
    'MEDIUM',
    'SALES_RETURN_PROCESS'
  );
end;
$$;

revoke all on function public.process_sales_return(uuid) from public;
revoke execute on function public.process_sales_return(uuid) from anon;
grant execute on function public.process_sales_return(uuid) to authenticated;

-- ============================================================================
-- FIX 4: post_inventory_movement — return_in with FX from order
-- Also: return_in should extract currency from order data
-- ============================================================================
create or replace function public.post_inventory_movement(p_movement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv record;
  v_entry_id uuid;
  v_inventory uuid;
  v_cogs uuid;
  v_ap uuid;
  v_ar uuid;
  v_shrinkage uuid;
  v_gain uuid;
  v_vat_input uuid;
  v_supplier_tax_total numeric;
  v_doc_type text;
  v_base text;
  v_po_currency text;
  v_po_fx_rate numeric;
  v_foreign_total numeric;
  v_supports_je_fx boolean := true;
  v_supports_jl_fx boolean := true;
  v_party_id uuid;
begin
  if p_movement_id is null then
    raise exception 'p_movement_id is required';
  end if;

  select * into v_mv from public.inventory_movements im where im.id = p_movement_id;
  if not found then
    raise exception 'inventory movement not found';
  end if;

  if v_mv.reference_table = 'production_orders' then
    return;
  end if;

  if exists (
    select 1 from public.journal_entries je
    where je.source_table = 'inventory_movements'
      and je.source_id = v_mv.id::text
      and je.source_event = v_mv.movement_type
  ) then
    return;
  end if;

  v_inventory := public.get_account_id_by_code('1410');
  v_cogs := public.get_account_id_by_code('5010');
  v_ap := public.get_account_id_by_code('2010');
  v_ar := public.get_account_id_by_code('1200');
  v_shrinkage := public.get_account_id_by_code('5020');
  v_gain := public.get_account_id_by_code('4021');
  v_vat_input := public.get_account_id_by_code('1420');
  v_supplier_tax_total := coalesce(nullif((v_mv.data->>'supplier_tax_total')::numeric, null), 0);

  v_base := null;
  begin
    v_base := public.get_base_currency();
  exception when undefined_function then
    v_base := null;
  end;
  if v_base is null or btrim(v_base) = '' then
    v_base := 'YER';
  end if;

  v_po_currency := null;
  v_po_fx_rate := null;
  v_foreign_total := null;
  v_party_id := null;

  if v_mv.reference_table = 'purchase_receipts' and v_mv.movement_type = 'purchase_in' then
    select po.currency, po.fx_rate, po.supplier_id
    into v_po_currency, v_po_fx_rate, v_party_id
    from public.purchase_receipts pr
    join public.purchase_orders po on po.id = pr.purchase_order_id
    where pr.id = v_mv.reference_id::uuid;
    if v_party_id is not null then
      v_party_id := public.ensure_financial_party_for_supplier(v_party_id);
    end if;
  elsif v_mv.reference_table = 'purchase_returns' and v_mv.movement_type = 'return_out' then
    select po.currency, po.fx_rate, po.supplier_id
    into v_po_currency, v_po_fx_rate, v_party_id
    from public.purchase_returns r
    join public.purchase_orders po on po.id = r.purchase_order_id
    where r.id = v_mv.reference_id::uuid;
    if v_party_id is not null then
      v_party_id := public.ensure_financial_party_for_supplier(v_party_id);
    end if;
  elsif v_mv.reference_table = 'orders' and v_mv.movement_type = 'sale_out' then
    begin
      select nullif(btrim(coalesce(o.data->>'currency', o.currency)), ''),
             nullif(coalesce((o.data->>'fxRate')::numeric, o.fx_rate), 0),
             o.customer_auth_user_id
      into v_po_currency, v_po_fx_rate, v_party_id
      from public.orders o
      where o.id = v_mv.reference_id::uuid;
      if v_party_id is not null then
        v_party_id := public.ensure_financial_party_for_customer(v_party_id);
      end if;
    exception when others then
      v_po_currency := null;
      v_po_fx_rate := null;
      v_party_id := null;
    end;
  -- FIX 4: return_in — extract currency from the original order via data->>'orderId'
  elsif v_mv.reference_table = 'sales_returns' and v_mv.movement_type = 'return_in' then
    begin
      -- Try to get currency from movement data (new format)
      v_po_currency := nullif(btrim(coalesce(v_mv.data->>'currency', '')), '');
      begin
        v_po_fx_rate := nullif((v_mv.data->>'fxRate')::numeric, 0);
      exception when others then
        v_po_fx_rate := null;
      end;

      -- Fallback: resolve from the original order
      if v_po_currency is null then
        declare
          v_order_id_text text;
        begin
          v_order_id_text := nullif(btrim(coalesce(v_mv.data->>'orderId', '')), '');
          if v_order_id_text is not null then
            select nullif(btrim(coalesce(o.data->>'currency', o.currency)), ''),
                   nullif(coalesce((o.data->>'fxRate')::numeric, o.fx_rate), 0)
            into v_po_currency, v_po_fx_rate
            from public.orders o
            where o.id = v_order_id_text::uuid;
          end if;
        exception when others then null;
        end;
      end if;
    exception when others then
      v_po_currency := null;
      v_po_fx_rate := null;
    end;
  end if;

  if v_po_currency is not null and upper(v_po_currency) <> upper(v_base) and coalesce(v_po_fx_rate, 0) > 0 then
    v_foreign_total := v_mv.total_cost / v_po_fx_rate;
    if v_party_id is not null then
      perform public.ensure_party_currency(v_party_id, v_po_currency);
    end if;
  else
    v_po_currency := null;
    v_po_fx_rate := null;
    v_foreign_total := null;
  end if;

  if v_mv.movement_type in ('wastage_out','adjust_out') then
    v_doc_type := 'writeoff';
  elsif v_mv.movement_type = 'purchase_in' then
    v_doc_type := 'grn';
  else
    v_doc_type := 'movement';
  end if;

  begin
    insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, currency_code, fx_rate, foreign_amount)
    values (
      v_mv.occurred_at,
      concat('Inventory movement ', v_mv.movement_type, ' ', v_mv.item_id),
      'inventory_movements',
      v_mv.id::text,
      v_mv.movement_type,
      v_mv.created_by,
      v_po_currency,
      v_po_fx_rate,
      v_foreign_total
    )
    returning id into v_entry_id;
  exception when undefined_column then
    v_supports_je_fx := false;
    insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
    values (
      v_mv.occurred_at,
      concat('Inventory movement ', v_mv.movement_type, ' ', v_mv.item_id),
      'inventory_movements',
      v_mv.id::text,
      v_mv.movement_type,
      v_mv.created_by
    )
    returning id into v_entry_id;
  end;

  if v_mv.movement_type = 'purchase_in' then
    begin
      if v_supplier_tax_total > 0 and v_vat_input is not null then
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
        values
          (v_entry_id, v_inventory, v_mv.total_cost - v_supplier_tax_total, 0, 'Inventory increase (net)',
           v_po_currency, v_po_fx_rate,
           case when v_foreign_total is not null and coalesce(v_po_fx_rate, 0) > 0 then (v_mv.total_cost - v_supplier_tax_total) / v_po_fx_rate else null end,
           null),
          (v_entry_id, v_vat_input, v_supplier_tax_total, 0, 'VAT input',
           v_po_currency, v_po_fx_rate,
           case when v_foreign_total is not null and coalesce(v_po_fx_rate, 0) > 0 then v_supplier_tax_total / v_po_fx_rate else null end,
           null),
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable',
           v_po_currency, v_po_fx_rate, v_foreign_total, v_party_id);
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
        values
          (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Inventory increase',
           v_po_currency, v_po_fx_rate, v_foreign_total, null),
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable',
           v_po_currency, v_po_fx_rate, v_foreign_total, v_party_id);
      end if;
    exception when undefined_column then
      v_supports_jl_fx := false;
      if v_supplier_tax_total > 0 and v_vat_input is not null then
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
        values
          (v_entry_id, v_inventory, v_mv.total_cost - v_supplier_tax_total, 0, 'Inventory increase (net)'),
          (v_entry_id, v_vat_input, v_supplier_tax_total, 0, 'VAT input'),
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable');
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
        values
          (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Inventory increase'),
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable');
      end if;
    end;
  elsif v_mv.movement_type = 'sale_out' then
    begin
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
      values
        (v_entry_id, v_cogs, v_mv.total_cost, 0, 'COGS',
         v_po_currency, v_po_fx_rate,
         case when v_foreign_total is not null then v_foreign_total else null end, null),
        (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease',
         v_po_currency, v_po_fx_rate,
         case when v_foreign_total is not null then v_foreign_total else null end, null);
    exception when undefined_column then
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
      values
        (v_entry_id, v_cogs, v_mv.total_cost, 0, 'COGS'),
        (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease');
    end;
  elsif v_mv.movement_type = 'wastage_out' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_shrinkage, v_mv.total_cost, 0, 'Wastage'),
      (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease');
  elsif v_mv.movement_type = 'adjust_in' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Adjustment in'),
      (v_entry_id, v_gain, 0, v_mv.total_cost, 'Inventory gain');
  elsif v_mv.movement_type = 'return_out' then
    begin
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
      values
        (v_entry_id, v_ap, v_mv.total_cost, 0, 'Vendor credit',
         v_po_currency, v_po_fx_rate, v_foreign_total, v_party_id),
        (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease',
         v_po_currency, v_po_fx_rate, v_foreign_total, null);
    exception when undefined_column then
      v_supports_jl_fx := false;
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
      values
        (v_entry_id, v_ap, v_mv.total_cost, 0, 'Vendor credit'),
        (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease');
    end;
  -- FIX 4: return_in now carries FX when available
  elsif v_mv.movement_type = 'return_in' then
    begin
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
      values
        (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Inventory restore (return)',
         v_po_currency, v_po_fx_rate,
         case when v_foreign_total is not null then v_foreign_total else null end),
        (v_entry_id, v_cogs, 0, v_mv.total_cost, 'Reverse COGS',
         v_po_currency, v_po_fx_rate,
         case when v_foreign_total is not null then v_foreign_total else null end);
    exception when undefined_column then
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
      values
        (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Inventory restore (return)'),
        (v_entry_id, v_cogs, 0, v_mv.total_cost, 'Reverse COGS');
    end;
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;

-- ============================================================================
-- FIX 3: create_purchase_return — use batch.unit_cost (base unit)
--        instead of purchase_items.unit_cost (purchase unit)
-- The key change: when looking up cost for return, prefer batch.unit_cost
-- which is already in base unit, over pi.unit_cost which may be in purchase unit.
-- ============================================================================
-- Note: The create_purchase_return function already uses v_batch.unit_cost
-- (from batches table) when batch tracking is active. The issue is when
-- v_po_unit_cost from purchase_items is used as fallback. We need to convert it.

-- Add a helper to safely get base-unit cost from purchase_items
create or replace function public._get_purchase_item_base_unit_cost(
  p_po_id uuid,
  p_item_id text
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_unit_cost numeric;
  v_factor numeric;
begin
  -- Get the raw unit cost and conversion factor
  begin
    select
      coalesce(nullif(pi.unit_cost_foreign, 0), nullif(pi.unit_cost, 0), 0),
      coalesce(nullif(pi.conversion_factor, 0), 1)
    into v_unit_cost, v_factor
    from public.purchase_items pi
    where pi.purchase_order_id = p_po_id
      and pi.item_id::text = p_item_id
    limit 1;
  exception when undefined_column then
    -- If conversion_factor column doesn't exist, try UOM lookup
    select coalesce(nullif(pi.unit_cost, 0), 0)
    into v_unit_cost
    from public.purchase_items pi
    where pi.purchase_order_id = p_po_id
      and pi.item_id::text = p_item_id
    limit 1;

    -- Try to get factor from menu_item_units
    begin
      select coalesce(nullif(miu.factor, 0), 1)
      into v_factor
      from public.purchase_items pi
      join public.menu_item_units miu
        on miu.item_id::text = pi.item_id::text
        and lower(btrim(miu.unit_name)) = lower(btrim(coalesce(pi.uom, '')))
      where pi.purchase_order_id = p_po_id
        and pi.item_id::text = p_item_id
      limit 1;
    exception when others then
      v_factor := 1;
    end;
  end;

  if not found then
    return 0;
  end if;

  -- Convert to base unit cost: if factor > 1 (e.g., carton=12), divide
  if coalesce(v_factor, 1) > 1 then
    return v_unit_cost / v_factor;
  end if;

  return coalesce(v_unit_cost, 0);
end;
$$;

notify pgrst, 'reload schema';
