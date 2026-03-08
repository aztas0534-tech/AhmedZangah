set app.allow_ledger_ddl = '1';

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
begin
  if auth.role() <> 'service_role' then
    perform public._require_staff('accounting.post');
  end if;

  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

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

  begin
    insert into public.journal_entries (
      entry_date, memo, source_table, source_id, source_event, status, currency_code, fx_rate
    ) values (
      v_delivered_at,
      'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
      'orders',
      p_order_id::text,
      'delivered',
      'posted',
      v_currency,
      v_fx
    )
    returning id into v_entry_id;
  exception when undefined_column then
    begin
      insert into public.journal_entries (
        entry_date, memo, source_table, source_id, source_event, status, currency, fx_rate
      ) values (
        v_delivered_at,
        'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
        'orders',
        p_order_id::text,
        'delivered',
        'posted',
        v_currency,
        v_fx
      )
      returning id into v_entry_id;
    exception when undefined_column then
      insert into public.journal_entries (
        entry_date, memo, source_table, source_id, source_event, status
      ) values (
        v_delivered_at,
        'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
        'orders',
        p_order_id::text,
        'delivered',
        'posted'
      )
      returning id into v_entry_id;
    end;
  end;

  if v_ar_amount_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_ar, v_ar_amount_base, 0, 'استحقاق آجل');
  end if;
  if v_deposits_paid_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_deposits, v_deposits_paid_base, 0, 'تسوية دفعات مقدمة/نقدية');
  end if;
  if v_items_revenue_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_sales, 0, v_items_revenue_base, 'إيرادات مبيعات');
  end if;
  if v_delivery_base > 0 then
    if v_delivery_income is null then raise exception 'Account Delivery Income (4020) not found'; end if;
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_delivery_income, 0, v_delivery_base, 'إيرادات توصيل');
  end if;
  if v_tax_base > 0 then
    if v_vat_payable is null then raise exception 'Account VAT Payable (2020) not found'; end if;
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_vat_payable, 0, v_tax_base, 'ضريبة القيمة المضافة');
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
exception when others then
  raise exception 'POST_DELIVERY_ERROR: %', SQLERRM;
end;
$$;

notify pgrst, 'reload schema';
