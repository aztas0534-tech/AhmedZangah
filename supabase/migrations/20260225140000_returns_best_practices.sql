set app.allow_ledger_ddl = '1';

do $$
begin
  if to_regclass('public.sales_returns') is not null then
    begin
      alter table public.sales_returns add column idempotency_key text;
    exception when duplicate_column then null;
    end;

    begin
      create unique index if not exists uq_sales_returns_order_idempotency
        on public.sales_returns(order_id, idempotency_key)
        where idempotency_key is not null and btrim(idempotency_key) <> '';
    exception when others then
      null;
    end;
  end if;

  if to_regclass('public.purchase_returns') is not null then
    begin
      alter table public.purchase_returns add column idempotency_key text;
    exception when duplicate_column then null;
    end;
  end if;
end $$;

create or replace function public.trg_sales_returns_audit_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'sales_returns.create',
    'sales',
    new.id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'salesReturnId', new.id::text,
      'orderId', new.order_id::text,
      'status', coalesce(new.status, ''),
      'refundMethod', coalesce(new.refund_method, ''),
      'amount', coalesce(new.total_refund_amount, 0),
      'idempotencyKey', coalesce(new.idempotency_key, '')
    ),
    'LOW',
    'SALES_RETURN_CREATE'
  );
  return null;
end;
$$;

create or replace function public.trg_sales_returns_audit_after_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(old.status,'') is distinct from coalesce(new.status,'') then
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
    values (
      'sales_returns.status',
      'sales',
      new.id::text,
      auth.uid(),
      now(),
      jsonb_build_object(
        'salesReturnId', new.id::text,
        'orderId', new.order_id::text,
        'from', coalesce(old.status,''),
        'to', coalesce(new.status,'')
      ),
      'MEDIUM',
      'SALES_RETURN_STATUS'
    );
  end if;
  return null;
end;
$$;

do $$
begin
  if to_regclass('public.sales_returns') is not null then
    drop trigger if exists trg_sales_returns_audit_ai on public.sales_returns;
    create trigger trg_sales_returns_audit_ai
    after insert on public.sales_returns
    for each row execute function public.trg_sales_returns_audit_after_insert();

    drop trigger if exists trg_sales_returns_audit_au on public.sales_returns;
    create trigger trg_sales_returns_audit_au
    after update on public.sales_returns
    for each row execute function public.trg_sales_returns_audit_after_update();
  end if;
end $$;

create or replace function public.recompute_purchase_order_amounts(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po record;
  v_base text;
  v_fx numeric;
  v_foreign_total numeric := 0;
  v_base_total numeric := 0;
  v_returns_base numeric := 0;
  v_returns_foreign numeric := 0;
  v_paid_foreign numeric := 0;
begin
  if p_order_id is null then
    return;
  end if;

  select *
  into v_po
  from public.purchase_orders po
  where po.id = p_order_id
  for update;
  if not found then
    return;
  end if;

  v_base := public.get_base_currency();
  v_fx := coalesce(v_po.fx_rate, 1);
  if v_fx <= 0 then
    v_fx := 1;
  end if;

  begin
    select coalesce(sum(coalesce(pi.qty_base, pi.quantity, 0) * coalesce(nullif(pi.unit_cost_foreign, 0), nullif(pi.unit_cost, 0), 0)), 0)
    into v_foreign_total
    from public.purchase_items pi
    where pi.purchase_order_id = p_order_id;
  exception when undefined_column then
    select coalesce(sum(coalesce(pi.total_cost, 0)), 0)
    into v_foreign_total
    from public.purchase_items pi
    where pi.purchase_order_id = p_order_id;
  end;

  if upper(coalesce(v_po.currency, v_base)) = upper(v_base) then
    v_base_total := v_foreign_total;
  else
    v_base_total := v_foreign_total * v_fx;
  end if;

  begin
    select coalesce(sum(coalesce(im.total_cost, 0)), 0)
    into v_returns_base
    from public.inventory_movements im
    join public.purchase_returns pr on pr.id::text = im.reference_id::text
    where pr.purchase_order_id = p_order_id
      and im.reference_table = 'purchase_returns'
      and im.movement_type = 'return_out';
  exception when others then
    v_returns_base := 0;
  end;

  if upper(coalesce(v_po.currency, v_base)) = upper(v_base) then
    v_returns_foreign := v_returns_base;
  else
    v_returns_foreign := case when v_fx > 0 then (v_returns_base / v_fx) else 0 end;
  end if;

  begin
    select coalesce(sum(coalesce(p.amount, 0)), 0)
    into v_paid_foreign
    from public.payments p
    where p.direction = 'out'
      and p.reference_table = 'purchase_orders'
      and p.reference_id = p_order_id::text;
  exception when others then
    v_paid_foreign := coalesce(v_po.paid_amount, 0);
  end;

  update public.purchase_orders
  set total_amount = greatest(0, coalesce(v_foreign_total, 0) - coalesce(v_returns_foreign, 0)),
      base_total = greatest(0, coalesce(v_base_total, 0) - coalesce(v_returns_base, 0)),
      paid_amount = coalesce(v_paid_foreign, 0),
      updated_at = now()
  where id = p_order_id;
end;
$$;

create or replace function public.trg_purchase_returns_recompute_po()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recompute_purchase_order_amounts(new.purchase_order_id);
  return null;
end;
$$;

do $$
begin
  if to_regclass('public.purchase_returns') is not null then
    drop trigger if exists trg_purchase_returns_recompute_po on public.purchase_returns;
    create constraint trigger trg_purchase_returns_recompute_po
    after insert or update on public.purchase_returns
    deferrable initially deferred
    for each row execute function public.trg_purchase_returns_recompute_po();
  end if;
end $$;

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
    v_ar_reduction := v_base_total_refund;
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
    v_refund_method := 'cash';
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
        id,
        item_id,
        receipt_item_id,
        receipt_id,
        warehouse_id,
        batch_code,
        production_date,
        expiry_date,
        quantity_received,
        quantity_consumed,
        unit_cost,
        qc_status,
        data
      )
      values (
        v_ret_batch_id,
        v_item_id::text,
        null,
        null,
        v_wh,
        null,
        v_source_batch.production_date,
        v_source_batch.expiry_date,
        v_alloc,
        0,
        coalesce(v_source_batch.unit_cost, 0),
        'approved',
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
        v_item_id::text,
        'return_in',
        v_alloc,
        coalesce(v_source_batch.unit_cost, 0),
        (v_alloc * coalesce(v_source_batch.unit_cost, 0)),
        'sales_returns',
        v_ret.id::text,
        coalesce(v_ret.return_date, now()),
        auth.uid(),
        jsonb_build_object('orderId', v_ret.order_id::text, 'sourceMovementId', v_sale.id::text),
        v_ret_batch_id,
        v_wh
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
      'currency', v_currency
    ),
    'MEDIUM',
    'SALES_RETURN_PROCESS'
  );
end;
$$;

revoke all on function public.process_sales_return(uuid) from public;
revoke execute on function public.process_sales_return(uuid) from anon;
grant execute on function public.process_sales_return(uuid) to authenticated;

notify pgrst, 'reload schema';
