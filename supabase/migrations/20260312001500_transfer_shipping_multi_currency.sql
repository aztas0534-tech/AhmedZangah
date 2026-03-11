set app.allow_ledger_ddl = '1';

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'warehouse_transfers' and column_name = 'shipping_cost_currency'
  ) then
    alter table public.warehouse_transfers add column shipping_cost_currency text;
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'warehouse_transfers' and column_name = 'shipping_cost_fx_rate'
  ) then
    alter table public.warehouse_transfers add column shipping_cost_fx_rate numeric;
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'warehouse_transfers' and column_name = 'shipping_cost_foreign'
  ) then
    alter table public.warehouse_transfers add column shipping_cost_foreign numeric;
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'warehouse_transfers' and column_name = 'shipping_cost_base'
  ) then
    alter table public.warehouse_transfers add column shipping_cost_base numeric;
  end if;
end $$;

create or replace function public.trg_set_transfer_shipping_fx()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
  v_curr text;
  v_fx numeric;
  v_date date;
begin
  v_base := public.get_base_currency();
  v_curr := upper(nullif(btrim(coalesce(new.shipping_cost_currency, '')), ''));
  if v_curr is null then
    v_curr := v_base;
  end if;
  new.shipping_cost_currency := v_curr;
  v_date := coalesce(new.transfer_date, current_date);

  if v_curr = v_base then
    new.shipping_cost_fx_rate := 1;
  elsif coalesce(new.shipping_cost_fx_rate, 0) <= 0 then
    v_fx := public.get_fx_rate(v_curr, v_date, 'operational');
    if v_fx is null or v_fx <= 0 then
      raise exception 'fx rate missing for currency % on %', v_curr, v_date;
    end if;
    new.shipping_cost_fx_rate := v_fx;
  end if;

  if coalesce(new.shipping_cost_foreign, 0) > 0 then
    new.shipping_cost := coalesce(new.shipping_cost_foreign, 0) * coalesce(new.shipping_cost_fx_rate, 1);
  elsif coalesce(new.shipping_cost, 0) > 0 then
    if v_curr = v_base then
      new.shipping_cost_foreign := new.shipping_cost;
      new.shipping_cost_fx_rate := 1;
    else
      new.shipping_cost_foreign := new.shipping_cost / nullif(new.shipping_cost_fx_rate, 0);
    end if;
  else
    new.shipping_cost := 0;
    new.shipping_cost_foreign := 0;
    if v_curr = v_base then
      new.shipping_cost_fx_rate := 1;
    elsif coalesce(new.shipping_cost_fx_rate, 0) <= 0 then
      new.shipping_cost_fx_rate := coalesce(public.get_fx_rate(v_curr, v_date, 'operational'), 1);
    end if;
  end if;

  new.shipping_cost_base := coalesce(new.shipping_cost, 0);
  return new;
end;
$$;

drop trigger if exists trg_set_transfer_shipping_fx on public.warehouse_transfers;
create trigger trg_set_transfer_shipping_fx
before insert or update of shipping_cost, shipping_cost_currency, shipping_cost_fx_rate, shipping_cost_foreign, transfer_date
on public.warehouse_transfers
for each row
execute function public.trg_set_transfer_shipping_fx();

update public.warehouse_transfers wt
set
  shipping_cost_currency = coalesce(upper(nullif(btrim(wt.shipping_cost_currency), '')), public.get_base_currency()),
  shipping_cost_fx_rate = case
    when coalesce(upper(nullif(btrim(wt.shipping_cost_currency), '')), public.get_base_currency()) = public.get_base_currency() then 1
    when coalesce(wt.shipping_cost_fx_rate, 0) > 0 then wt.shipping_cost_fx_rate
    else coalesce(public.get_fx_rate(coalesce(upper(nullif(btrim(wt.shipping_cost_currency), '')), public.get_base_currency()), coalesce(wt.transfer_date, current_date), 'operational'), 1)
  end,
  shipping_cost_foreign = case
    when coalesce(upper(nullif(btrim(wt.shipping_cost_currency), '')), public.get_base_currency()) = public.get_base_currency() then coalesce(wt.shipping_cost, 0)
    when coalesce(wt.shipping_cost_fx_rate, 0) > 0 then coalesce(wt.shipping_cost, 0) / wt.shipping_cost_fx_rate
    else coalesce(wt.shipping_cost, 0)
  end,
  shipping_cost_base = coalesce(wt.shipping_cost, 0);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'warehouse_transfers_shipping_cost_fx_rate_pos'
      and conrelid = 'public.warehouse_transfers'::regclass
  ) then
    alter table public.warehouse_transfers
      add constraint warehouse_transfers_shipping_cost_fx_rate_pos
      check (coalesce(shipping_cost_fx_rate, 0) > 0);
  end if;
end $$;

notify pgrst, 'reload schema';
