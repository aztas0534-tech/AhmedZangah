set app.allow_ledger_ddl = '1';

-- ============================================================================
-- Fix post_inventory_movement to:
--   1. Set party_id on AP journal lines for purchase_in (supplier party)
--   2. Set party_id on AR-related lines for sale_out (customer party)
--   3. Auto-register party currency via ensure_party_currency
--   4. Enhance _resolve_party_for_entry to resolve customers for sale_out
-- ============================================================================

-- Fix _resolve_party_for_entry to also resolve customers from orders
create or replace function public._resolve_party_for_entry(p_source_table text, p_source_id text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party_id uuid;
  v_order record;
  v_po record;
  v_pay record;
  v_exp record;
  v_party_text text;
  v_emp uuid;
begin
  v_party_id := null;

  if p_source_table = 'orders' then
    begin
      select o.customer_auth_user_id, o.currency, o.fx_rate, o.total, o.base_total
      into v_order
      from public.orders o
      where o.id = (p_source_id)::uuid;
      if v_order.customer_auth_user_id is not null then
        v_party_id := public.ensure_financial_party_for_customer(v_order.customer_auth_user_id);
      end if;
    exception when others then
      v_party_id := null;
    end;
    return v_party_id;
  end if;

  if p_source_table = 'purchase_receipts' or p_source_table = 'purchase_orders' then
    begin
      if p_source_table = 'purchase_receipts' then
        select po.supplier_id
        into v_po
        from public.purchase_receipts pr
        join public.purchase_orders po on po.id = pr.purchase_order_id
        where pr.id = (p_source_id)::uuid;
      else
        select po.supplier_id
        into v_po
        from public.purchase_orders po
        where po.id = (p_source_id)::uuid;
      end if;
      if v_po.supplier_id is not null then
        v_party_id := public.ensure_financial_party_for_supplier(v_po.supplier_id);
      end if;
    exception when others then
      v_party_id := null;
    end;
    return v_party_id;
  end if;

  if p_source_table = 'inventory_movements' then
    -- Try to resolve from the inventory movement's context
    declare
      v_im record;
    begin
      select im.movement_type, im.reference_table, im.reference_id, im.data
      into v_im
      from public.inventory_movements im
      where im.id = (p_source_id)::uuid;

      -- For sale_out: resolve customer from order
      if v_im.movement_type = 'sale_out' and v_im.reference_table = 'orders' then
        begin
          select o.customer_auth_user_id
          into v_order
          from public.orders o
          where o.id = (v_im.reference_id)::uuid;
          if v_order.customer_auth_user_id is not null then
            return public.ensure_financial_party_for_customer(v_order.customer_auth_user_id);
          end if;
        exception when others then null;
        end;
      end if;

      -- For purchase_in: resolve supplier from PO via receipt
      if v_im.movement_type = 'purchase_in' and v_im.reference_table = 'purchase_receipts' then
        begin
          select po.supplier_id
          into v_po
          from public.purchase_receipts pr
          join public.purchase_orders po on po.id = pr.purchase_order_id
          where pr.id = (v_im.reference_id)::uuid;
          if v_po.supplier_id is not null then
            return public.ensure_financial_party_for_supplier(v_po.supplier_id);
          end if;
        exception when others then null;
        end;
      end if;

      -- For return_out: resolve supplier from purchase return
      if v_im.movement_type = 'return_out' and v_im.reference_table = 'purchase_returns' then
        begin
          select po.supplier_id
          into v_po
          from public.purchase_returns r
          join public.purchase_orders po on po.id = r.purchase_order_id
          where r.id = (v_im.reference_id)::uuid;
          if v_po.supplier_id is not null then
            return public.ensure_financial_party_for_supplier(v_po.supplier_id);
          end if;
        exception when others then null;
        end;
      end if;
    exception when others then null;
    end;
    return null;
  end if;

  if p_source_table = 'payments' then
    begin
      select *
      into v_pay
      from public.payments p
      where p.id = (p_source_id)::uuid;
    exception when others then
      return null;
    end;
    if v_pay.id is null then
      return null;
    end if;
    if v_pay.reference_table = 'orders' then
      begin
        select o.customer_auth_user_id
        into v_order
        from public.orders o
        where o.id = (v_pay.reference_id)::uuid;
        if v_order.customer_auth_user_id is not null then
          return public.ensure_financial_party_for_customer(v_order.customer_auth_user_id);
        end if;
      exception when others then null;
      end;
    end if;
    if v_pay.reference_table = 'financial_parties' then
      begin
        v_party_id := nullif(trim(coalesce(v_pay.reference_id, '')), '')::uuid;
        return v_party_id;
      exception when others then
        return null;
      end;
    end if;
    if v_pay.reference_table = 'expenses' then
      begin
        select e.data
        into v_exp
        from public.expenses e
        where e.id = (v_pay.reference_id)::uuid;
      exception when others then
        v_exp := null;
      end;
      if v_exp is not null then
        v_party_text := nullif(btrim(coalesce(v_exp.data->>'partyId', '')), '');
        if v_party_text is not null then
          begin
            v_party_id := v_party_text::uuid;
            return v_party_id;
          exception when others then null;
          end;
        end if;
        v_party_text := nullif(btrim(coalesce(v_exp.data->>'employeeId', '')), '');
        if v_party_text is not null then
          begin
            v_emp := v_party_text::uuid;
            return public.ensure_financial_party_for_employee(v_emp);
          exception when others then
            null;
          end;
        end if;
      end if;
      return null;
    end if;
  end if;

  if p_source_table = 'expenses' then
    begin
      select e.data into v_exp from public.expenses e where e.id = (p_source_id)::uuid;
    exception when others then
      v_exp := null;
    end;
    if v_exp is not null then
      v_party_text := nullif(btrim(coalesce(v_exp.data->>'partyId', '')), '');
      if v_party_text is not null then
        begin
          v_party_id := v_party_text::uuid;
          return v_party_id;
        exception when others then null;
        end;
      end if;
      v_party_text := nullif(btrim(coalesce(v_exp.data->>'employeeId', '')), '');
      if v_party_text is not null then
        begin
          v_emp := v_party_text::uuid;
          return public.ensure_financial_party_for_employee(v_emp);
        exception when others then
          null;
        end;
      end if;
    end if;
    return null;
  end if;

  return null;
end;
$$;

-- ============================================================================
-- Updated post_inventory_movement: add party_id on AP/AR lines
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
    -- Resolve supplier party
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
      -- Resolve customer party
      if v_party_id is not null then
        v_party_id := public.ensure_financial_party_for_customer(v_party_id);
      end if;
    exception when others then
      v_po_currency := null;
      v_po_fx_rate := null;
      v_party_id := null;
    end;
  end if;

  if v_po_currency is not null and upper(v_po_currency) <> upper(v_base) and coalesce(v_po_fx_rate, 0) > 0 then
    v_foreign_total := v_mv.total_cost / v_po_fx_rate;
    -- Auto-register currency for party
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
          -- AP line: set party_id for supplier
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable',
           v_po_currency, v_po_fx_rate, v_foreign_total,
           v_party_id);
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount, party_id)
        values
          (v_entry_id, v_inventory, v_mv.total_cost, 0, 'Inventory increase',
           v_po_currency, v_po_fx_rate, v_foreign_total, null),
          -- AP line: set party_id for supplier
          (v_entry_id, v_ap, 0, v_mv.total_cost, 'Supplier payable',
           v_po_currency, v_po_fx_rate, v_foreign_total,
           v_party_id);
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
         case when v_foreign_total is not null then v_foreign_total else null end,
         null),
        (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease',
         v_po_currency, v_po_fx_rate,
         case when v_foreign_total is not null then v_foreign_total else null end,
         null);
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
        -- AP debit: set party_id for supplier
        (v_entry_id, v_ap, v_mv.total_cost, 0, 'Vendor credit',
         v_po_currency, v_po_fx_rate, v_foreign_total,
         v_party_id),
        (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease',
         v_po_currency, v_po_fx_rate, v_foreign_total,
         null);
    exception when undefined_column then
      v_supports_jl_fx := false;
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
      values
        (v_entry_id, v_ap, v_mv.total_cost, 0, 'Vendor credit'),
        (v_entry_id, v_inventory, 0, v_mv.total_cost, 'Inventory decrease');
    end;
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
