set app.allow_ledger_ddl = '1';

create or replace function public.recompute_purchase_return_item_costs(p_return_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_qty numeric;
  v_total numeric;
  v_unit numeric;
begin
  if p_return_id is null then
    return;
  end if;

  for v_row in
    select pri.item_id::text as item_id
    from public.purchase_return_items pri
    where pri.return_id = p_return_id
    group by pri.item_id::text
  loop
    select coalesce(sum(coalesce(pri.quantity, 0)), 0)
    into v_qty
    from public.purchase_return_items pri
    where pri.return_id = p_return_id
      and pri.item_id::text = v_row.item_id;

    select coalesce(sum(coalesce(im.total_cost, 0)), 0)
    into v_total
    from public.inventory_movements im
    where im.reference_table = 'purchase_returns'
      and im.reference_id::text = p_return_id::text
      and im.movement_type = 'return_out'
      and im.item_id::text = v_row.item_id;

    if coalesce(v_qty, 0) <= 0 then
      continue;
    end if;

    if coalesce(v_total, 0) > 0 then
      v_unit := v_total / v_qty;
      update public.purchase_return_items pri
      set unit_cost = v_unit,
          total_cost = coalesce(pri.quantity, 0) * v_unit
      where pri.return_id = p_return_id
        and pri.item_id::text = v_row.item_id;
    end if;
  end loop;
end;
$$;

create or replace function public.trg_purchase_returns_recompute_item_costs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recompute_purchase_return_item_costs(new.id);
  return new;
end;
$$;

drop trigger if exists trg_purchase_returns_recompute_item_costs on public.purchase_returns;
create constraint trigger trg_purchase_returns_recompute_item_costs
after insert or update
on public.purchase_returns
deferrable initially deferred
for each row
execute function public.trg_purchase_returns_recompute_item_costs();

create or replace function public.create_purchase_return_v2(
  p_order_id uuid,
  p_items jsonb,
  p_reason text default null,
  p_occurred_at timestamptz default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_existing uuid;
  v_created uuid;
begin
  if v_key is not null then
    select pr.id
    into v_existing
    from public.purchase_returns pr
    where pr.purchase_order_id = p_order_id
      and pr.idempotency_key = v_key
    limit 1;
    if v_existing is not null then
      perform public.recompute_purchase_return_item_costs(v_existing);
      return v_existing;
    end if;
  end if;

  if v_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('purchase_return:' || p_order_id::text || ':' || v_key, 0));
    select pr.id
    into v_existing
    from public.purchase_returns pr
    where pr.purchase_order_id = p_order_id
      and pr.idempotency_key = v_key
    limit 1;
    if v_existing is not null then
      perform public.recompute_purchase_return_item_costs(v_existing);
      return v_existing;
    end if;
  end if;

  begin
    if to_regprocedure('public.reconcile_purchase_order_receipt_status(uuid)') is not null then
      perform public.reconcile_purchase_order_receipt_status(p_order_id);
    end if;
  exception when others then
    null;
  end;

  v_created := public.create_purchase_return(p_order_id, p_items, p_reason, p_occurred_at);

  if v_key is not null then
    begin
      update public.purchase_returns
      set idempotency_key = v_key
      where id = v_created
        and (idempotency_key is null or btrim(idempotency_key) = '');
    exception when unique_violation then
      select pr.id
      into v_existing
      from public.purchase_returns pr
      where pr.purchase_order_id = p_order_id
        and pr.idempotency_key = v_key
      limit 1;
      if v_existing is not null then
        perform public.recompute_purchase_return_item_costs(v_existing);
        return v_existing;
      end if;
      raise;
    end;
  end if;

  perform public.recompute_purchase_return_item_costs(v_created);

  return v_created;
end;
$$;

do $$
begin
  begin
    alter table public.journal_entries add column currency_code text;
  exception when duplicate_column then null;
  end;
  begin
    alter table public.journal_entries add column fx_rate numeric;
  exception when duplicate_column then null;
  end;
  begin
    alter table public.journal_entries add column foreign_amount numeric;
  exception when duplicate_column then null;
  end;
  begin
    alter table public.journal_entries add column party_id uuid;
  exception when duplicate_column then null;
  end;

  begin
    alter table public.journal_lines add column currency_code text;
  exception when duplicate_column then null;
  end;
  begin
    alter table public.journal_lines add column fx_rate numeric;
  exception when duplicate_column then null;
  end;
  begin
    alter table public.journal_lines add column foreign_amount numeric;
  exception when duplicate_column then null;
  end;
  begin
    alter table public.journal_lines add column party_id uuid;
  exception when duplicate_column then null;
  end;
end $$;

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
  v_shrinkage uuid;
  v_gain uuid;
  v_vat_input uuid;
  v_supplier_tax_total numeric;
  v_base text;
  v_currency text;
  v_fx numeric;
  v_foreign_total numeric;
  v_party_id uuid;
begin
  if p_movement_id is null then
    raise exception 'p_movement_id is required';
  end if;

  select *
  into v_mv
  from public.inventory_movements im
  where im.id = p_movement_id;

  if not found then
    raise exception 'inventory movement not found';
  end if;

  if v_mv.reference_table = 'production_orders' then
    return;
  end if;

  select je.id
  into v_entry_id
  from public.journal_entries je
  where je.source_table = 'inventory_movements'
    and je.source_id = v_mv.id::text
    and je.source_event = v_mv.movement_type
  limit 1;
  if v_entry_id is not null then
    return;
  end if;

  v_inventory := public.get_account_id_by_code('1410');
  v_cogs := public.get_account_id_by_code('5010');
  v_ap := public.get_account_id_by_code('2010');
  v_shrinkage := public.get_account_id_by_code('5020');
  v_gain := public.get_account_id_by_code('4021');
  v_vat_input := public.get_account_id_by_code('1420');
  v_supplier_tax_total := coalesce(nullif((v_mv.data->>'supplier_tax_total')::numeric, null), 0);

  v_base := upper(coalesce(public.get_base_currency(), 'YER'));
  v_currency := null;
  v_fx := null;
  v_foreign_total := null;
  v_party_id := null;

  if v_mv.reference_table = 'purchase_receipts' and v_mv.movement_type = 'purchase_in' then
    select upper(nullif(btrim(po.currency), '')), nullif(po.fx_rate, 0), po.supplier_id
    into v_currency, v_fx, v_party_id
    from public.purchase_receipts pr
    join public.purchase_orders po on po.id = pr.purchase_order_id
    where pr.id = v_mv.reference_id::uuid;
  elsif v_mv.reference_table = 'purchase_returns' and v_mv.movement_type = 'return_out' then
    select upper(nullif(btrim(po.currency), '')), nullif(po.fx_rate, 0), po.supplier_id
    into v_currency, v_fx, v_party_id
    from public.purchase_returns pr
    join public.purchase_orders po on po.id = pr.purchase_order_id
    where pr.id = v_mv.reference_id::uuid;
  elsif v_mv.reference_table = 'orders' and v_mv.movement_type = 'sale_out' then
    select upper(nullif(btrim(o.currency), '')), nullif(o.fx_rate, 0), o.party_id
    into v_currency, v_fx, v_party_id
    from public.orders o
    where o.id = v_mv.reference_id::uuid;
  end if;

  if v_currency is null or v_currency = '' or upper(v_currency) = v_base or coalesce(v_fx, 0) <= 0 then
    v_currency := null;
    v_fx := null;
    v_foreign_total := null;
  else
    v_foreign_total := v_mv.total_cost / v_fx;
  end if;

  insert into public.journal_entries(
    entry_date, memo, source_table, source_id, source_event, created_by,
    currency_code, fx_rate, foreign_amount, party_id
  )
  values (
    v_mv.occurred_at,
    concat('Inventory movement ', v_mv.movement_type, ' ', v_mv.item_id),
    'inventory_movements',
    v_mv.id::text,
    v_mv.movement_type,
    v_mv.created_by,
    v_currency,
    v_fx,
    v_foreign_total,
    v_party_id
  )
  returning id into v_entry_id;

  if v_mv.movement_type = 'purchase_in' then
    if v_supplier_tax_total > 0 and v_vat_input is not null then
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
      values
        (v_entry_id, v_inventory, public._money_round(v_mv.total_cost), 0, 'Inventory increase (net)', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id),
        (v_entry_id, v_vat_input, public._money_round(v_supplier_tax_total), 0, 'VAT recoverable', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_supplier_tax_total) / v_fx) else null end, v_party_id),
        (v_entry_id, v_ap, 0, public._money_round(v_mv.total_cost + v_supplier_tax_total), 'Supplier payable', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost + v_supplier_tax_total) / v_fx) else null end, v_party_id);
    else
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
      values
        (v_entry_id, v_inventory, public._money_round(v_mv.total_cost), 0, 'Inventory increase', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id),
        (v_entry_id, v_ap, 0, public._money_round(v_mv.total_cost), 'Supplier payable', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id);
    end if;
  elsif v_mv.movement_type = 'sale_out' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values
      (v_entry_id, v_cogs, public._money_round(v_mv.total_cost), 0, 'COGS', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id),
      (v_entry_id, v_inventory, 0, public._money_round(v_mv.total_cost), 'Inventory decrease', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id);
  elsif v_mv.movement_type = 'wastage_out' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values
      (v_entry_id, v_shrinkage, public._money_round(v_mv.total_cost), 0, 'Wastage', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, null),
      (v_entry_id, v_inventory, 0, public._money_round(v_mv.total_cost), 'Inventory decrease', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, null);
  elsif v_mv.movement_type = 'adjust_out' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values
      (v_entry_id, v_shrinkage, public._money_round(v_mv.total_cost), 0, 'Adjustment out', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, null),
      (v_entry_id, v_inventory, 0, public._money_round(v_mv.total_cost), 'Inventory decrease', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, null);
  elsif v_mv.movement_type = 'adjust_in' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values
      (v_entry_id, v_inventory, public._money_round(v_mv.total_cost), 0, 'Adjustment in', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, null),
      (v_entry_id, v_gain, 0, public._money_round(v_mv.total_cost), 'Inventory gain', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, null);
  elsif v_mv.movement_type = 'return_out' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values
      (v_entry_id, v_ap, public._money_round(v_mv.total_cost), 0, 'Vendor credit', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id),
      (v_entry_id, v_inventory, 0, public._money_round(v_mv.total_cost), 'Inventory decrease', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id);
  elsif v_mv.movement_type = 'return_in' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
    values
      (v_entry_id, v_inventory, public._money_round(v_mv.total_cost), 0, 'Inventory restore (return)', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id),
      (v_entry_id, v_cogs, 0, public._money_round(v_mv.total_cost), 'Reverse COGS', v_currency, v_fx, case when v_fx is not null and v_fx > 0 then (public._money_round(v_mv.total_cost) / v_fx) else null end, v_party_id);
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;

notify pgrst, 'reload schema';
