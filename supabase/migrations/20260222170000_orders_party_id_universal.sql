set app.allow_ledger_ddl = '1';

do $$
begin
  if to_regclass('public.orders') is not null then
    begin
      alter table public.orders
        add column party_id uuid references public.financial_parties(id) on delete set null;
    exception when duplicate_column then
      null;
    end;
    create index if not exists idx_orders_party_id on public.orders(party_id);
  end if;
end $$;

create or replace function public.trg_set_order_party_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party_text text;
  v_party uuid;
  v_exists boolean;
begin
  if new.party_id is not null then
    return new;
  end if;

  v_party_text := nullif(btrim(coalesce(new.data->>'partyId','')), '');
  if v_party_text is not null then
    begin
      v_party := v_party_text::uuid;
      select exists(select 1 from public.financial_parties fp where fp.id = v_party) into v_exists;
      if v_exists then
        new.party_id := v_party;
        return new;
      end if;
    exception when others then
      null;
    end;
  end if;

  if new.customer_auth_user_id is not null then
    begin
      new.party_id := public.ensure_financial_party_for_customer(new.customer_auth_user_id);
    exception when others then
      null;
    end;
  end if;

  return new;
end;
$$;

do $$
begin
  if to_regclass('public.orders') is not null then
    drop trigger if exists trg_set_order_party_id on public.orders;
    create trigger trg_set_order_party_id
    before insert or update on public.orders
    for each row execute function public.trg_set_order_party_id();
  end if;
end $$;

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
      select o.party_id, o.customer_auth_user_id, o.currency, o.fx_rate, o.total, o.base_total
      into v_order
      from public.orders o
      where o.id = (p_source_id)::uuid;
      if v_order.party_id is not null then
        return v_order.party_id;
      end if;
      if v_order.customer_auth_user_id is not null then
        v_party_id := public.ensure_financial_party_for_customer(v_order.customer_auth_user_id);
      end if;
    exception when others then
      v_party_id := null;
    end;
    return v_party_id;
  end if;

  if p_source_table = 'purchase_orders' then
    begin
      select po.supplier_id, po.currency, po.fx_rate, po.total_amount, po.base_total
      into v_po
      from public.purchase_orders po
      where po.id = (p_source_id)::uuid;
      if v_po.supplier_id is not null then
        v_party_id := public.ensure_financial_party_for_supplier(v_po.supplier_id);
      end if;
    exception when others then
      v_party_id := null;
    end;
    return v_party_id;
  end if;

  if p_source_table = 'inventory_movements' then
    begin
      select po.supplier_id
      into v_po
      from public.inventory_movements im
      left join public.batches b on b.id = im.batch_id
      left join public.purchase_receipts pr on pr.id = b.receipt_id
      left join public.purchase_orders po on po.id = pr.purchase_order_id
      where im.id = (p_source_id)::uuid;
    exception when others then
      v_po := null;
    end;
    if v_po.supplier_id is not null then
      return public.ensure_financial_party_for_supplier(v_po.supplier_id);
    end if;
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
      return public._resolve_party_for_entry('orders', v_pay.reference_id);
    end if;
    if v_pay.reference_table = 'purchase_orders' then
      return public._resolve_party_for_entry('purchase_orders', v_pay.reference_id);
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
        v_party_text := nullif(trim(coalesce(v_exp.data->>'partyId','')), '');
        if v_party_text is not null then
          begin
            return v_party_text::uuid;
          exception when others then
            null;
          end;
        end if;
        v_party_text := nullif(trim(coalesce(v_exp.data->>'employeeId','')), '');
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
      v_party_text := nullif(trim(coalesce(v_exp.data->>'partyId','')), '');
      if v_party_text is not null then
        begin
          return v_party_text::uuid;
        exception when others then
          null;
        end;
      end if;
      v_party_text := nullif(trim(coalesce(v_exp.data->>'employeeId','')), '');
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

create or replace function public.trg_orders_forbid_posted_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status = 'delivered' then
    if (new.data is distinct from old.data)
      or (new.currency is distinct from old.currency)
      or (new.fx_rate is distinct from old.fx_rate)
      or (new.base_total is distinct from old.base_total)
      or (new.warehouse_id is distinct from old.warehouse_id)
      or (new.party_id is distinct from old.party_id)
    then
      raise exception 'posted_order_immutable';
    end if;
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';
