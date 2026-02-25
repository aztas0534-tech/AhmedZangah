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
  perform public._require_staff('accounting.post');

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
  v_deposits := public.get_account_id_by_code(coalesce(v_accounts->>'deposits','2050'));
  v_sales := public.get_account_id_by_code(coalesce(v_accounts->>'sales','4010'));
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
      and p.occurred_at < v_delivered_at;
  exception when undefined_column then
    select coalesce(sum(coalesce(p.amount, 0)), 0) * v_fx
    into v_deposits_paid_base
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
      and p.direction = 'in'
      and p.occurred_at < v_delivered_at;
  end;

  v_deposits_paid_base := least(v_total_base, greatest(0, coalesce(v_deposits_paid_base, 0)));
  v_ar_amount_base := greatest(0, v_total_base - v_deposits_paid_base);

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, currency_code, fx_rate, foreign_amount)
  values (
    v_delivered_at,
    concat('Order delivered ', v_order.id::text),
    'orders',
    v_order.id::text,
    'delivered',
    auth.uid(),
    case when v_currency <> v_base then v_currency else null end,
    case when v_currency <> v_base then v_fx else null end,
    case when v_currency <> v_base then coalesce(nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null), nullif((v_data->>'total')::numeric, null), coalesce(v_order.total, 0), 0) else null end
  )
  returning id into v_entry_id;

  if v_deposits_paid_base > 0 and v_deposits is not null then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_deposits, v_deposits_paid_base, 0, 'Apply customer deposit');
  end if;

  if v_ar_amount_base > 0 and v_ar is not null then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_ar, v_ar_amount_base, 0, 'Accounts receivable');
  end if;

  if v_items_revenue_base > 0 and v_sales is not null then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_sales, 0, v_items_revenue_base, 'Sales revenue');
  end if;

  if v_delivery_base > 0 and v_delivery_income is not null then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_delivery_income, 0, v_delivery_base, 'Delivery income');
  end if;

  if v_tax_base > 0 and v_vat_payable is not null then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_vat_payable, 0, v_tax_base, 'VAT payable');
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;

revoke all on function public.post_order_delivery(uuid) from public;
revoke execute on function public.post_order_delivery(uuid) from anon;
grant execute on function public.post_order_delivery(uuid) to authenticated;

notify pgrst, 'reload schema';

