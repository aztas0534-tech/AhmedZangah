set app.allow_ledger_ddl = '1';

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'warehouse_transfer_items' and column_name = 'uom_id'
  ) then
    alter table public.warehouse_transfer_items add column uom_id uuid references public.uom(id);
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'warehouse_transfer_items' and column_name = 'qty_base'
  ) then
    alter table public.warehouse_transfer_items add column qty_base numeric;
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'warehouse_transfer_items' and column_name = 'qty_trx'
  ) then
    alter table public.warehouse_transfer_items add column qty_trx numeric;
  end if;
end $$;

create or replace function public.trg_set_qty_base_warehouse_transfer_items()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base uuid;
  v_qty_input numeric;
begin
  select iu.base_uom_id
  into v_base
  from public.item_uom iu
  where iu.item_id::text = new.item_id::text
  limit 1;

  v_qty_input := coalesce(new.qty_trx, new.quantity, 0);
  if coalesce(v_qty_input, 0) <= 0 then
    raise exception 'quantity must be positive';
  end if;

  if v_base is null then
    new.qty_trx := v_qty_input;
    new.qty_base := v_qty_input;
    new.quantity := v_qty_input;
    return new;
  end if;

  if new.uom_id is null then
    new.uom_id := v_base;
  end if;

  new.qty_trx := v_qty_input;
  new.qty_base := public.item_qty_to_base(new.item_id::text, v_qty_input, new.uom_id);
  new.quantity := new.qty_base;
  return new;
end;
$$;

drop trigger if exists trg_set_qty_base_warehouse_transfer_items on public.warehouse_transfer_items;
create trigger trg_set_qty_base_warehouse_transfer_items
before insert or update of item_id, quantity, qty_trx, qty_base, uom_id
on public.warehouse_transfer_items
for each row
execute function public.trg_set_qty_base_warehouse_transfer_items();

update public.warehouse_transfer_items wti
set
  uom_id = coalesce(wti.uom_id, iu.base_uom_id),
  qty_trx = coalesce(wti.qty_trx, wti.quantity),
  qty_base = coalesce(wti.qty_base, wti.quantity),
  quantity = coalesce(wti.qty_base, wti.quantity)
from public.item_uom iu
where iu.item_id::text = wti.item_id::text;

do $$
begin
  if to_regprocedure('public.post_inventory_movement_core(uuid)') is null
     and to_regprocedure('public.post_inventory_movement(uuid)') is not null then
    execute 'alter function public.post_inventory_movement(uuid) rename to post_inventory_movement_core';
  end if;
end $$;

create or replace function public.post_inventory_movement(p_movement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref_table text;
begin
  select im.reference_table
  into v_ref_table
  from public.inventory_movements im
  where im.id = p_movement_id;

  if coalesce(v_ref_table, '') = 'warehouse_transfers' then
    return;
  end if;

  if to_regprocedure('public.post_inventory_movement_core(uuid)') is null then
    return;
  end if;

  perform public.post_inventory_movement_core(p_movement_id);
end;
$$;

revoke all on function public.post_inventory_movement(uuid) from public;
grant execute on function public.post_inventory_movement(uuid) to authenticated;

create or replace function public.post_warehouse_transfer_shipping(p_transfer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer record;
  v_accounts jsonb;
  v_inventory uuid;
  v_clearing uuid;
  v_entry_id uuid;
  v_branch uuid;
  v_company uuid;
  v_amount numeric;
  v_currency text;
  v_fx numeric;
  v_foreign numeric;
begin
  select
    wt.id,
    wt.transfer_date,
    wt.status,
    wt.to_warehouse_id,
    wt.created_by,
    wt.approved_by,
    coalesce(wt.shipping_cost_base, wt.shipping_cost, 0) as shipping_base,
    coalesce(nullif(upper(btrim(coalesce(wt.shipping_cost_currency, ''))), ''), public.get_base_currency()) as shipping_currency,
    coalesce(wt.shipping_cost_fx_rate, 1) as shipping_fx_rate,
    coalesce(wt.shipping_cost_foreign, wt.shipping_cost, 0) as shipping_foreign
  into v_transfer
  from public.warehouse_transfers wt
  where wt.id = p_transfer_id
  limit 1;

  if not found then
    return;
  end if;

  if coalesce(v_transfer.status, '') <> 'completed' then
    return;
  end if;

  v_amount := round(coalesce(v_transfer.shipping_base, 0), 6);
  if v_amount <= 0 then
    return;
  end if;

  if exists (
    select 1
    from public.journal_entries je
    where je.source_table = 'warehouse_transfers'
      and je.source_id = p_transfer_id::text
      and je.source_event = 'shipping_capitalization'
  ) then
    return;
  end if;

  select s.data->'settings'->'accounting_accounts'
  into v_accounts
  from public.app_settings s
  where s.id = 'app';

  if v_accounts is null then
    select s.data->'accounting_accounts'
    into v_accounts
    from public.app_settings s
    where s.id = 'singleton';
  end if;

  v_inventory := null;
  if v_accounts is not null and nullif(v_accounts->>'inventory', '') is not null then
    begin
      v_inventory := (v_accounts->>'inventory')::uuid;
    exception when others then
      v_inventory := public.get_account_id_by_code(v_accounts->>'inventory');
    end;
  end if;
  v_inventory := coalesce(v_inventory, public.get_account_id_by_code('1410'));

  v_clearing := null;
  if v_accounts is not null and nullif(v_accounts->>'landed_cost_clearing', '') is not null then
    begin
      v_clearing := (v_accounts->>'landed_cost_clearing')::uuid;
    exception when others then
      v_clearing := public.get_account_id_by_code(v_accounts->>'landed_cost_clearing');
    end;
  end if;
  v_clearing := coalesce(v_clearing, public.get_account_id_by_code('2060'));

  if v_inventory is null or v_clearing is null then
    raise exception 'Missing accounting accounts for transfer shipping capitalization (inventory %, landed_cost_clearing %)',
      coalesce(v_accounts->>'inventory', '1410'),
      coalesce(v_accounts->>'landed_cost_clearing', '2060');
  end if;

  v_branch := coalesce(public.branch_from_warehouse(v_transfer.to_warehouse_id), public.get_default_branch_id());
  v_company := coalesce(public.company_from_branch(v_branch), public.get_default_company_id());

  insert into public.journal_entries(
    id, source_table, source_id, source_event, entry_date, memo, created_by, branch_id, company_id
  )
  values (
    gen_random_uuid(),
    'warehouse_transfers',
    p_transfer_id::text,
    'shipping_capitalization',
    coalesce(v_transfer.transfer_date, current_date),
    concat('Transfer shipping capitalization ', p_transfer_id::text),
    coalesce(v_transfer.approved_by, v_transfer.created_by, auth.uid()),
    v_branch,
    v_company
  )
  returning id into v_entry_id;

  v_currency := v_transfer.shipping_currency;
  v_fx := coalesce(v_transfer.shipping_fx_rate, 1);
  v_foreign := coalesce(v_transfer.shipping_foreign, 0);

  begin
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, fx_rate, foreign_amount)
    values
      (v_entry_id, v_inventory, v_amount, 0, 'Transfer shipping capitalization', v_currency, v_fx, v_foreign),
      (v_entry_id, v_clearing, 0, v_amount, 'Transfer shipping clearing', v_currency, v_fx, v_foreign);
  exception when undefined_column then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_inventory, v_amount, 0, 'Transfer shipping capitalization'),
      (v_entry_id, v_clearing, 0, v_amount, 'Transfer shipping clearing');
  end;

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;

create or replace function public.trg_post_warehouse_transfer_shipping()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE'
     and coalesce(old.status, '') <> 'completed'
     and coalesce(new.status, '') = 'completed' then
    perform public.post_warehouse_transfer_shipping(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_post_warehouse_transfer_shipping on public.warehouse_transfers;
create trigger trg_post_warehouse_transfer_shipping
after update of status on public.warehouse_transfers
for each row
execute function public.trg_post_warehouse_transfer_shipping();

notify pgrst, 'reload schema';
