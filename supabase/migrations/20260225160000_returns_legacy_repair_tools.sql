set app.allow_ledger_ddl = '1';

create or replace function public.repair_sales_return_journal_only(
  p_return_id uuid,
  p_dry_run boolean default false
)
returns json
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
  v_currency text;
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
  v_refund_method text;
  v_exists boolean := false;
begin
  if not (auth.role() = 'service_role' or public.has_admin_permission('accounting.manage')) then
    raise exception 'not authorized';
  end if;

  if p_return_id is null then
    raise exception 'p_return_id is required';
  end if;

  select *
  into v_ret
  from public.sales_returns r
  where r.id = p_return_id;
  if not found then
    raise exception 'sales return not found';
  end if;

  if coalesce(v_ret.status,'') <> 'completed' then
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'not_completed', 'salesReturnId', v_ret.id::text);
  end if;

  select *
  into v_order
  from public.orders o
  where o.id = v_ret.order_id;
  if not found then
    raise exception 'order not found';
  end if;

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

  v_cash := public.get_account_id_by_code('1010');
  v_bank := public.get_account_id_by_code('1020');
  v_ar := public.get_account_id_by_code('1200');
  v_deposits := public.get_account_id_by_code('2050');
  v_sales_returns := public.get_account_id_by_code('4026');
  v_vat_payable := public.get_account_id_by_code('2020');

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

  select je.id
  into v_entry_id
  from public.journal_entries je
  where je.source_table = 'sales_returns'
    and je.source_id = v_ret.id::text
    and je.source_event = 'processed'
  order by je.entry_date desc, je.id desc
  limit 1;
  if found then
    v_exists := true;
  end if;

  if not v_exists then
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
    returning id into v_entry_id;
  else
    update public.journal_entries
    set entry_date = coalesce(v_ret.return_date, entry_date),
        memo = concat('Sales return ', v_ret.id::text),
        status = 'posted'
    where id = v_entry_id;
  end if;

  begin
    update public.journal_entries
    set currency_code = case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
        fx_rate = case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
        foreign_amount = case when upper(v_currency) = upper(v_base_currency) then null else v_total_refund end
    where id = v_entry_id;
  exception when undefined_column then
  end;

  if p_dry_run then
    return jsonb_build_object(
      'ok', true,
      'dryRun', true,
      'salesReturnId', v_ret.id::text,
      'journalEntryId', v_entry_id::text,
      'currency', v_currency,
      'baseCurrency', v_base_currency,
      'fx', v_fx,
      'totalRefund', v_total_refund,
      'baseTotalRefund', v_base_total_refund
    );
  end if;

  delete from public.journal_lines jl where jl.journal_entry_id = v_entry_id;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
  values (
    v_entry_id,
    v_sales_returns,
    v_base_return_subtotal,
    0,
    'Sales return',
    case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
    case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
    case when upper(v_currency) = upper(v_base_currency) then null else v_return_subtotal end
  );

  if v_tax_refund > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (
      v_entry_id,
      v_vat_payable,
      v_base_tax_refund,
      0,
      'Reverse VAT payable',
      case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_tax_refund end
    );
  end if;

  if v_refund_method = 'cash' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (
      v_entry_id,
      v_cash,
      0,
      v_base_total_refund,
      'Cash refund',
      case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_total_refund end
    );
  elsif v_refund_method in ('network','kuraimi') then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (
      v_entry_id,
      v_bank,
      0,
      v_base_total_refund,
      'Bank refund',
      case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_total_refund end
    );
  elsif v_refund_method = 'ar' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (
      v_entry_id,
      v_ar,
      0,
      v_base_total_refund,
      'Reduce accounts receivable',
      case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_total_refund end
    );
  elsif v_refund_method = 'store_credit' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (
      v_entry_id,
      v_deposits,
      0,
      v_base_total_refund,
      'Increase customer deposit',
      case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_total_refund end
    );
  else
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values (
      v_entry_id,
      v_cash,
      0,
      v_base_total_refund,
      'Cash refund',
      case when upper(v_currency) = upper(v_base_currency) then null else v_currency end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_fx end,
      case when upper(v_currency) = upper(v_base_currency) then null else v_total_refund end
    );
  end if;

  perform public.check_journal_entry_balance(v_entry_id);

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'sales_returns.repair_journal',
    'sales',
    v_ret.id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'salesReturnId', v_ret.id::text,
      'orderId', v_ret.order_id::text,
      'journalEntryId', v_entry_id::text,
      'currency', v_currency,
      'baseCurrency', v_base_currency,
      'fx', v_fx,
      'totalRefund', v_total_refund,
      'baseTotalRefund', v_base_total_refund
    ),
    'MEDIUM',
    'SALES_RETURN_JOURNAL_REPAIR'
  );

  return jsonb_build_object('ok', true, 'salesReturnId', v_ret.id::text, 'journalEntryId', v_entry_id::text);
end;
$$;

revoke all on function public.repair_sales_return_journal_only(uuid, boolean) from public;
revoke execute on function public.repair_sales_return_journal_only(uuid, boolean) from anon;
grant execute on function public.repair_sales_return_journal_only(uuid, boolean) to authenticated;

create or replace function public.repair_sales_returns_journals_batch(p_limit integer default 500)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text := upper(coalesce(public.get_base_currency(), 'YER'));
  v_count int := 0;
  v_fixed int := 0;
  r record;
  v_res json;
begin
  if not (auth.role() = 'service_role' or public.has_admin_permission('accounting.manage')) then
    raise exception 'not authorized';
  end if;

  for r in
    select sr.id as return_id
    from public.sales_returns sr
    join public.orders o on o.id = sr.order_id
    where coalesce(sr.status,'') = 'completed'
      and upper(coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency','')), ''), v_base)) <> v_base
      and exists (
        select 1
        from public.journal_entries je
        where je.source_table = 'sales_returns'
          and je.source_id = sr.id::text
          and je.source_event = 'processed'
        limit 1
      )
      and not exists (
        select 1
        from public.journal_entries je
        join public.journal_lines jl on jl.journal_entry_id = je.id
        where je.source_table = 'sales_returns'
          and je.source_id = sr.id::text
          and je.source_event = 'processed'
          and upper(coalesce(jl.currency_code, '')) <> ''
          and jl.fx_rate is not null
          and jl.foreign_amount is not null
        limit 1
      )
    order by sr.created_at desc
    limit greatest(1, least(p_limit, 5000))
  loop
    v_count := v_count + 1;
    begin
      v_res := public.repair_sales_return_journal_only(r.return_id, false);
      if coalesce((v_res->>'ok')::boolean, false) then
        v_fixed := v_fixed + 1;
      end if;
    exception when others then
    end;
  end loop;

  return jsonb_build_object('ok', true, 'candidates', v_count, 'fixed', v_fixed);
end;
$$;

revoke all on function public.repair_sales_returns_journals_batch(integer) from public;
revoke execute on function public.repair_sales_returns_journals_batch(integer) from anon;
grant execute on function public.repair_sales_returns_journals_batch(integer) to authenticated;

create or replace function public.recompute_purchase_orders_from_returns(p_limit integer default 5000)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int := 0;
  r record;
begin
  if not (auth.role() = 'service_role' or public.has_admin_permission('accounting.manage')) then
    raise exception 'not authorized';
  end if;

  for r in
    select distinct pr.purchase_order_id as order_id
    from public.purchase_returns pr
    where pr.purchase_order_id is not null
    order by pr.purchase_order_id
    limit greatest(1, least(p_limit, 20000))
  loop
    begin
      perform public.recompute_purchase_order_amounts(r.order_id);
      v_count := v_count + 1;
    exception when others then
    end;
  end loop;

  return jsonb_build_object('ok', true, 'recomputed', v_count);
end;
$$;

revoke all on function public.recompute_purchase_orders_from_returns(integer) from public;
revoke execute on function public.recompute_purchase_orders_from_returns(integer) from anon;
grant execute on function public.recompute_purchase_orders_from_returns(integer) to authenticated;

notify pgrst, 'reload schema';

