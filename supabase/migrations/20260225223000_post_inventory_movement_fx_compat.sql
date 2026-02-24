set app.allow_ledger_ddl = '1';

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
  v_doc_type text;
  v_po_currency text;
  v_po_fx_rate numeric;
  v_foreign_total numeric;
  v_supports_je_fx boolean := true;
  v_supports_jl_fx boolean := true;
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
  v_shrinkage := public.get_account_id_by_code('5020');
  v_gain := public.get_account_id_by_code('4021');
  v_vat_input := public.get_account_id_by_code('1420');
  v_supplier_tax_total := coalesce(nullif((v_mv.data->>'supplier_tax_total')::numeric, null), 0);

  v_po_currency := null;
  v_po_fx_rate := null;
  v_foreign_total := null;

  if v_mv.movement_type = 'purchase_in' and v_mv.reference_table = 'purchase_receipts' then
    select po.currency, po.fx_rate
    into v_po_currency, v_po_fx_rate
    from public.purchase_receipts pr
    join public.purchase_orders po on po.id = pr.purchase_order_id
    where pr.id = v_mv.reference_id::uuid;

    if v_po_currency is not null and v_po_currency <> 'SAR' and coalesce(v_po_fx_rate, 0) > 0 then
      v_foreign_total := v_mv.total_cost / v_po_fx_rate;
    else
      v_po_currency := null;
      v_po_fx_rate := null;
    end if;
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
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
        values
          (v_entry_id, v_inventory, v_mv.total_cost - v_supplier_tax_total, 0, 'Inventory increase (net)',
           v_po_currency, v_po_fx_rate,
           case when v_foreign_total is not null and coalesce(v_po_fx_rate, 0) > 0 then (v_mv.total_cost - v_supplier_tax_total) / v_po_fx_rate else null end),
          (v_entry_id, v_vat_input, v_supplier_tax_total, 0, 'VAT input',
           v_po_currency, v_po_fx_rate,
           case when v_foreign_total is not null and coalesce(v_po_fx_rate, 0) > 0 then v_supplier_tax_total / v_po_fx_rate else null end),
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable',
           v_po_currency, v_po_fx_rate, v_foreign_total);
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
        values
          (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Inventory increase',
           v_po_currency, v_po_fx_rate, v_foreign_total),
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable',
           v_po_currency, v_po_fx_rate, v_foreign_total);
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
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_cogs, v_mv.total_cost, 0, 'COGS'),
      (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease');
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
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_ap, v_mv.total_cost, 0, 'Vendor credit'),
      (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease');
  elsif v_mv.movement_type = 'return_in' then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Inventory restore (return)'),
      (v_entry_id, v_cogs, 0, v_mv.total_cost, 'Reverse COGS');
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;

notify pgrst, 'reload schema';

