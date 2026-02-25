-- Fix for "GL is append-only" error by making post_order_delivery idempotent
-- Robust version: handles both 'currency' and 'currency_code' columns
-- Robust version: handles missing accounts gracefully or with clear errors
create or replace function public.post_order_delivery(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_entry_id uuid;
  v_total_base numeric := 0;
  v_ar uuid;
  v_deposits uuid;
  v_sales uuid;
  v_delivery_income uuid;
  v_vat_payable uuid;
  v_delivered_at timestamptz;
  v_deposits_paid_base numeric := 0;
  v_ar_amount_base numeric := 0;
  v_delivery_base numeric := 0;
  v_tax_base numeric := 0;
  v_items_revenue_base numeric := 0;
  v_accounts jsonb;
  v_base text;
  v_currency text;
  v_fx numeric;
  v_data jsonb;
  v_has_currency_code boolean;
begin
  -- Permission check
  perform public._require_staff('accounting.post');

  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

  -- IDEMPOTENCY CHECK
  if exists (
    select 1
    from public.journal_entries je
    where je.source_table = 'orders'
      and je.source_id = p_order_id::text
      and je.source_event = 'delivered'
    limit 1
  ) then
    return;
  end if;

  select o.*
  into v_order
  from public.orders o
  where o.id = p_order_id;
  if not found then
    raise exception 'order not found';
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'YER'));
  v_data := coalesce(v_order.data, '{}'::jsonb);
  v_currency := upper(nullif(btrim(coalesce(v_order.currency, v_data->>'currency', v_base)), ''));
  if v_currency is null then
    v_currency := v_base;
  end if;
  v_fx := coalesce(v_order.fx_rate, nullif((v_data->>'fxRate')::numeric, null), 1);
  if v_fx is null or v_fx <= 0 then
    v_fx := 1;
  end if;

  if v_order.base_total is not null then
    v_total_base := coalesce(v_order.base_total, 0);
  else
    v_total_base := coalesce(nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null), nullif((v_data->>'total')::numeric, null), coalesce(v_order.total, 0), 0) * v_fx;
  end if;
  if coalesce(v_total_base, 0) <= 0 then
    return;
  end if;

  select s.data->'accounting_accounts' into v_accounts from public.app_settings s where s.id = 'singleton';
  
  -- Resolve Accounts
  v_ar := public.get_account_id_by_code(coalesce(v_accounts->>'ar','1200'));
  if v_ar is null then raise exception 'Account AR (1200) not found'; end if;

  v_deposits := public.get_account_id_by_code(coalesce(v_accounts->>'deposits','2050'));
  if v_deposits is null then raise exception 'Account Deposits (2050) not found'; end if;

  v_sales := public.get_account_id_by_code(coalesce(v_accounts->>'sales','4010'));
  if v_sales is null then raise exception 'Account Sales (4010) not found'; end if;

  v_delivery_income := public.get_account_id_by_code(coalesce(v_accounts->>'delivery_income','4020'));
  v_vat_payable := public.get_account_id_by_code(coalesce(v_accounts->>'vat_payable','2020'));

  v_delivered_at := public.order_delivered_at(p_order_id);
  if v_delivered_at is null then
    v_delivered_at := coalesce(v_order.updated_at, now());
  end if;

  v_delivery_base := coalesce(nullif((v_data->'invoiceSnapshot'->>'deliveryFee')::numeric, null), nullif((v_data->>'deliveryFee')::numeric, null), coalesce(v_order.delivery_fee, 0), 0) * v_fx;
  v_tax_base := coalesce(nullif((v_data->'invoiceSnapshot'->>'taxAmount')::numeric, null), nullif((v_data->>'taxAmount')::numeric, null), coalesce(v_order.tax, 0), 0) * v_fx;

  v_tax_base := least(greatest(0, v_tax_base), v_total_base);
  v_delivery_base := least(greatest(0, v_delivery_base), v_total_base - v_tax_base);
  v_items_revenue_base := greatest(0, v_total_base - v_delivery_base - v_tax_base);

  begin
    select coalesce(sum(coalesce(p.base_amount, 0)), 0)
    into v_deposits_paid_base
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
      and p.direction = 'in'
      and p.status = 'paid';
  exception when others then
    v_deposits_paid_base := 0;
  end;

  v_ar_amount_base := greatest(0, v_total_base - v_deposits_paid_base);

  -- Insert Journal Entry with Robust Column Handling
  begin
    -- Try inserting with currency_code (New Schema)
    insert into public.journal_entries (
      entry_date,
      memo,
      source_table,
      source_id,
      source_event,
      status,
      currency_code,
      fx_rate
    ) values (
      v_delivered_at,
      'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
      'orders',
      p_order_id::text,
      'delivered',
      'posted',
      v_currency,
      v_fx
    ) returning id into v_entry_id;
  exception when undefined_column then
    -- Fallback: Try inserting with currency (Old Schema) or neither
    begin
        insert into public.journal_entries (
          entry_date,
          memo,
          source_table,
          source_id,
          source_event,
          status,
          currency,
          fx_rate
        ) values (
          v_delivered_at,
          'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
          'orders',
          p_order_id::text,
          'delivered',
          'posted',
          v_currency,
          v_fx
        ) returning id into v_entry_id;
    exception when undefined_column then
        -- Fallback: Insert without currency columns (Oldest Schema)
        insert into public.journal_entries (
          entry_date,
          memo,
          source_table,
          source_id,
          source_event,
          status
        ) values (
          v_delivered_at,
          'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
          'orders',
          p_order_id::text,
          'delivered',
          'posted'
        ) returning id into v_entry_id;
    end;
  end;

  -- 1. Debit AR (Receivables)
  if v_ar_amount_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_ar, v_ar_amount_base, 0, 'استحقاق آجل');
  end if;

  -- 2. Debit Deposits
  if v_deposits_paid_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_deposits, v_deposits_paid_base, 0, 'تسوية دفعات مقدمة/نقدية');
  end if;

  -- 3. Credit Sales Revenue
  if v_items_revenue_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_sales, 0, v_items_revenue_base, 'إيرادات مبيعات');
  end if;

  -- 4. Credit Delivery Income
  if v_delivery_base > 0 then
    if v_delivery_income is null then raise exception 'Account Delivery Income (4020) not found'; end if;
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_delivery_income, 0, v_delivery_base, 'إيرادات توصيل');
  end if;

  -- 5. Credit VAT Payable
  if v_tax_base > 0 then
    if v_vat_payable is null then raise exception 'Account VAT Payable (2020) not found'; end if;
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_vat_payable, 0, v_tax_base, 'ضريبة القيمة المضافة');
  end if;

  -- Validate balance
  perform public.check_journal_entry_balance(v_entry_id);

exception when others then
  raise exception 'POST_DELIVERY_ERROR: %', SQLERRM;
end;
$$;

-- Trigger to prevent auto-cancellation of in-store orders
create or replace function public.trg_prevent_instore_auto_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src text;
  v_reason text;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  if coalesce(old.status, '') <> 'pending' then
    return new;
  end if;

  if coalesce(new.status, '') <> 'cancelled' then
    return new;
  end if;

  v_src := coalesce(nullif(btrim(coalesce(new.data->>'orderSource','')), ''), nullif(btrim(coalesce(old.data->>'orderSource','')), ''), '');
  if v_src <> 'in_store' then
    return new;
  end if;

  if nullif(btrim(coalesce(new.data->>'deliveredAt','')), '') is not null then
    return new;
  end if;

  v_reason := nullif(btrim(coalesce(new.data->>'cancelReason','')), '');
  if v_reason is null then
    v_reason := 'in_store_failed';
  end if;

  new.status := 'pending';
  new.data := coalesce(new.data, '{}'::jsonb);
  new.data := jsonb_set(new.data, '{inStoreFailureAt}', to_jsonb(now()), true);
  new.data := jsonb_set(new.data, '{inStoreFailureReason}', to_jsonb(v_reason), true);
  return new;
end;
$$;

drop trigger if exists trg_prevent_instore_auto_cancel on public.orders;
create trigger trg_prevent_instore_auto_cancel
before update on public.orders
for each row execute function public.trg_prevent_instore_auto_cancel();

revoke all on function public.trg_prevent_instore_auto_cancel() from public;

notify pgrst, 'reload schema';
