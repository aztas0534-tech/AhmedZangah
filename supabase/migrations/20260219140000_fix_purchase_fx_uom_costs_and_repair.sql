-- Fix: purchase_items unit_cost_base trigger was converting UOM only (not FX),
-- leading to foreign costs being treated as base currency.
-- This caused inflated batch costs, inventory movements, and journal entries for foreign-currency purchases.

set app.allow_ledger_ddl = '1';

-- 1) Unify purchase_items cost/qty trigger: UOM + FX aware
create or replace function public.trg_purchase_items_set_qty_costs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base_currency text;
  v_po record;
  v_base_uom uuid;
  v_foreign_uom_cost numeric;
  v_fx numeric;
  v_po_currency text;
begin
  if new.item_id is null or btrim(new.item_id) = '' then
    return new;
  end if;

  v_base_currency := upper(coalesce(public.get_base_currency(), ''));
  if v_base_currency = '' then
    v_base_currency := 'SAR';
  end if;

  v_base_uom := null;
  begin
    select iu.base_uom_id into v_base_uom from public.item_uom iu where iu.item_id = new.item_id limit 1;
  exception when others then
    v_base_uom := null;
  end;
  if v_base_uom is not null and new.uom_id is null then
    new.uom_id := v_base_uom;
  end if;

  begin
    new.qty_base := public.item_qty_to_base(new.item_id, coalesce(new.quantity, 0), new.uom_id);
  exception when others then
    new.qty_base := coalesce(new.quantity, 0);
  end;

  -- Resolve PO currency & FX (base per 1 foreign)
  v_po := null;
  if new.purchase_order_id is not null then
    select po.currency, po.fx_rate into v_po
    from public.purchase_orders po
    where po.id = new.purchase_order_id;
  end if;
  v_po_currency := upper(coalesce(nullif(btrim(coalesce(v_po.currency, '')), ''), v_base_currency));
  v_fx := coalesce(v_po.fx_rate, 1);
  if v_fx is null or v_fx <= 0 then
    v_fx := 1;
  end if;

  -- Treat unit_cost as entered in PO currency.
  -- Store unit_cost_foreign as per-base-UOM in PO currency (even if PO currency == base).
  if new.unit_cost_foreign is null then
    new.unit_cost_foreign := coalesce(new.unit_cost, 0);
  end if;

  begin
    v_foreign_uom_cost := public.item_unit_cost_to_base(new.item_id, coalesce(new.unit_cost_foreign, 0), new.uom_id);
  exception when others then
    v_foreign_uom_cost := coalesce(new.unit_cost_foreign, 0);
  end;
  if v_foreign_uom_cost is null or v_foreign_uom_cost < 0 then
    v_foreign_uom_cost := 0;
  end if;
  new.unit_cost_foreign := v_foreign_uom_cost;

  -- Compute base cost per base UOM
  if v_po_currency = v_base_currency then
    new.unit_cost_base := v_foreign_uom_cost;
  else
    new.unit_cost_base := round(v_foreign_uom_cost * v_fx, 6);
  end if;

  return new;
end;
$$;

do $$
begin
  if to_regclass('public.purchase_items') is null then
    return;
  end if;
  drop trigger if exists trg_purchase_items_set_costs on public.purchase_items;
  drop trigger if exists trg_set_qty_base_purchase_items on public.purchase_items;
  drop trigger if exists trg_purchase_items_set_qty_costs on public.purchase_items;
  create trigger trg_purchase_items_set_qty_costs
    before insert or update of quantity, uom_id, unit_cost, unit_cost_foreign, purchase_order_id
    on public.purchase_items
    for each row execute function public.trg_purchase_items_set_qty_costs();
end $$;

-- 2) Backfill purchase_items using the same logic
do $$
declare
  v_base text;
begin
  if to_regclass('public.purchase_items') is null or to_regclass('public.purchase_orders') is null then
    return;
  end if;
  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  update public.purchase_items pi
  set
    qty_base = coalesce(pi.qty_base, public.item_qty_to_base(pi.item_id, coalesce(pi.quantity,0), coalesce(pi.uom_id, (select base_uom_id from public.item_uom where item_id = pi.item_id limit 1)))),
    unit_cost_foreign = public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost_foreign, pi.unit_cost, 0), coalesce(pi.uom_id, (select base_uom_id from public.item_uom where item_id = pi.item_id limit 1))),
    unit_cost_base =
      case
        when upper(coalesce(po.currency, v_base)) = v_base then
          public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost_foreign, pi.unit_cost, 0), coalesce(pi.uom_id, (select base_uom_id from public.item_uom where item_id = pi.item_id limit 1)))
        else
          round(
            public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost_foreign, pi.unit_cost, 0), coalesce(pi.uom_id, (select base_uom_id from public.item_uom where item_id = pi.item_id limit 1)))
            * coalesce(nullif(po.fx_rate, 0), 1),
            6
          )
      end
  from public.purchase_orders po
  where po.id = pi.purchase_order_id
    and (
      pi.qty_base is null
      or pi.unit_cost_base is null
      or pi.unit_cost_base = 0
      or (
        upper(coalesce(po.currency, v_base)) <> v_base
        and abs(coalesce(pi.unit_cost_base, 0) - coalesce(pi.unit_cost_foreign, pi.unit_cost, 0)) <= greatest(0.01, abs(coalesce(pi.unit_cost_base,0)) * 0.01)
      )
    );
end $$;

-- 3) Repair foreign-currency receipts/batches/movements using corrected purchase_items
do $$
declare
  v_base text;
begin
  if to_regclass('public.purchase_orders') is null
     or to_regclass('public.purchase_receipts') is null
     or to_regclass('public.purchase_receipt_items') is null
     or to_regclass('public.purchase_items') is null
     or to_regclass('public.batches') is null
     or to_regclass('public.inventory_movements') is null then
    return;
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  -- Compute expected goods costs (foreign/base) per PO+item in base UOM
  with pi_avg as (
    select
      pi.purchase_order_id,
      pi.item_id,
      upper(coalesce(po.currency, v_base)) as po_currency,
      coalesce(nullif(po.fx_rate, 0), 1) as fx_rate,
      case
        when sum(coalesce(pi.qty_base, 0)) > 0 then sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_foreign, 0)) / sum(coalesce(pi.qty_base, 0))
        else max(coalesce(pi.unit_cost_foreign, 0))
      end as goods_unit_cost_foreign,
      case
        when upper(coalesce(po.currency, v_base)) = v_base then
          case
            when sum(coalesce(pi.qty_base, 0)) > 0 then sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_foreign, 0)) / sum(coalesce(pi.qty_base, 0))
            else max(coalesce(pi.unit_cost_foreign, 0))
          end
        else
          round(
            (case
              when sum(coalesce(pi.qty_base, 0)) > 0 then sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_foreign, 0)) / sum(coalesce(pi.qty_base, 0))
              else max(coalesce(pi.unit_cost_foreign, 0))
            end) * coalesce(nullif(po.fx_rate, 0), 1),
            6
          )
      end as goods_unit_cost_base
    from public.purchase_items pi
    join public.purchase_orders po on po.id = pi.purchase_order_id
    group by pi.purchase_order_id, pi.item_id, upper(coalesce(po.currency, v_base)), coalesce(nullif(po.fx_rate, 0), 1)
  ),
  pri_fix as (
    select
      pri.id as pri_id,
      pr.purchase_order_id,
      pri.item_id,
      po.currency as po_currency,
      po.fx_rate as po_fx,
      avg.goods_unit_cost_foreign,
      avg.goods_unit_cost_base,
      (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_unit_cost_base,
      (coalesce(pri.quantity, 0) * (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0))) as expected_total_cost
    from public.purchase_receipt_items pri
    join public.purchase_receipts pr on pr.id = pri.receipt_id
    join public.purchase_orders po on po.id = pr.purchase_order_id
    join pi_avg avg on avg.purchase_order_id = pr.purchase_order_id and avg.item_id = pri.item_id
    where upper(coalesce(po.currency, v_base)) <> v_base
      and coalesce(po.fx_rate, 0) > 0
  ),
  pri_candidates as (
    select *
    from pri_fix
    where
      -- only fix when current costs are clearly off
      abs(coalesce((select unit_cost from public.purchase_receipt_items x where x.id = pri_id), 0) - coalesce(expected_unit_cost_base, 0))
        > greatest(0.01, abs(coalesce(expected_unit_cost_base, 0)) * 0.05)
  )
  update public.purchase_receipt_items pri
  set
    unit_cost = round(c.expected_unit_cost_base, 6),
    total_cost = round(c.expected_total_cost, 6)
  from pri_candidates c
  where pri.id = c.pri_id;

  -- Update batches to match receipt items and store correct foreign snapshot (goods only)
  with pi_avg as (
    select
      pi.purchase_order_id,
      pi.item_id,
      upper(coalesce(po.currency, v_base)) as po_currency,
      coalesce(nullif(po.fx_rate, 0), 1) as fx_rate,
      case
        when sum(coalesce(pi.qty_base, 0)) > 0 then sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_foreign, 0)) / sum(coalesce(pi.qty_base, 0))
        else max(coalesce(pi.unit_cost_foreign, 0))
      end as goods_unit_cost_foreign
    from public.purchase_items pi
    join public.purchase_orders po on po.id = pi.purchase_order_id
    group by pi.purchase_order_id, pi.item_id, upper(coalesce(po.currency, v_base)), coalesce(nullif(po.fx_rate, 0), 1)
  ),
  b_fix as (
    select
      b.id as batch_id,
      pr.purchase_order_id,
      b.item_id,
      upper(coalesce(po.currency, v_base)) as po_currency,
      coalesce(nullif(po.fx_rate, 0), 1) as fx_rate,
      avg.goods_unit_cost_foreign,
      (coalesce(pri.unit_cost, b.unit_cost, 0)) as expected_unit_cost_base
    from public.batches b
    join public.purchase_receipts pr on pr.id = b.receipt_id
    join public.purchase_orders po on po.id = pr.purchase_order_id
    left join public.purchase_receipt_items pri on pri.receipt_id = b.receipt_id and pri.item_id = b.item_id
    join pi_avg avg on avg.purchase_order_id = pr.purchase_order_id and avg.item_id = b.item_id
    where upper(coalesce(po.currency, v_base)) <> v_base
      and coalesce(po.fx_rate, 0) > 0
      and coalesce(b.status,'active') = 'active'
  )
  update public.batches b
  set
    foreign_currency = f.po_currency,
    fx_rate_at_receipt = f.fx_rate,
    foreign_unit_cost = round(f.goods_unit_cost_foreign, 6),
    unit_cost = round(f.expected_unit_cost_base, 6),
    updated_at = now()
  from b_fix f
  where b.id = f.batch_id
    and (
      b.fx_rate_at_receipt is distinct from f.fx_rate
      or upper(coalesce(b.foreign_currency, '')) is distinct from f.po_currency
      or abs(coalesce(b.unit_cost, 0) - coalesce(f.expected_unit_cost_base, 0)) > greatest(0.01, abs(coalesce(f.expected_unit_cost_base, 0)) * 0.05)
      or abs(coalesce(b.foreign_unit_cost, 0) - coalesce(f.goods_unit_cost_foreign, 0)) > greatest(0.01, abs(coalesce(f.goods_unit_cost_foreign, 0)) * 0.05)
    );

  -- Sync purchase_in inventory movements to the corrected batch cost
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_forbid_modify_posted;
  end if;

  update public.inventory_movements im
  set
    unit_cost = round(coalesce(b.unit_cost, 0), 6),
    total_cost = round(coalesce(im.quantity, 0) * round(coalesce(b.unit_cost, 0), 6), 6)
  from public.batches b
  where b.id = im.batch_id
    and im.movement_type = 'purchase_in'
    and nullif(btrim(coalesce(b.foreign_currency,'')), '') is not null
    and upper(btrim(coalesce(b.foreign_currency,''))) <> upper(v_base)
    and abs(coalesce(im.total_cost, 0) - (coalesce(im.quantity, 0) * round(coalesce(b.unit_cost, 0), 6)))
      > greatest(0.01, abs(coalesce(im.total_cost, 0)) * 0.05);

  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted;
  end if;
end $$;

-- 4) Repair posted journal lines/entries for foreign purchase_in movements based on corrected batch costs
do $$
declare
  v_base text;
begin
  if to_regclass('public.journal_entries') is null or to_regclass('public.journal_lines') is null then
    return;
  end if;
  if to_regclass('public.inventory_movements') is null or to_regclass('public.batches') is null then
    return;
  end if;
  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  perform set_config('app.allow_ledger_ddl', '1', true);
  alter table public.journal_entries disable trigger user;
  alter table public.journal_lines disable trigger user;

  with candidates as (
    select
      je.id as entry_id,
      upper(b.foreign_currency) as currency_code,
      b.fx_rate_at_receipt as fx_rate,
      round(coalesce(im.quantity, 0) * round(coalesce(b.unit_cost, 0), 6), 6) as expected_base,
      round((coalesce(im.quantity, 0) * round(coalesce(b.unit_cost, 0), 6)) / nullif(b.fx_rate_at_receipt, 0), 6) as expected_foreign
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    join public.journal_entries je
      on je.source_table = 'inventory_movements'
     and je.source_id = im.id::text
     and je.status = 'posted'
    where im.movement_type = 'purchase_in'
      and nullif(btrim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(btrim(coalesce(b.foreign_currency,''))) <> upper(v_base)
      and b.fx_rate_at_receipt is not null
      and b.fx_rate_at_receipt > 0
  ),
  line_stats as (
    select
      jl.journal_entry_id as entry_id,
      count(*) as line_count,
      sum(case when coalesce(jl.debit, 0) > 0 then 1 else 0 end) as debit_lines,
      sum(case when coalesce(jl.credit, 0) > 0 then 1 else 0 end) as credit_lines
    from public.journal_lines jl
    join candidates c on c.entry_id = jl.journal_entry_id
    group by jl.journal_entry_id
  ),
  fixable as (
    select c.*
    from candidates c
    join line_stats ls on ls.entry_id = c.entry_id
    where ls.line_count = 2 and ls.debit_lines = 1 and ls.credit_lines = 1
  )
  update public.journal_lines jl
  set
    debit = case when coalesce(jl.debit, 0) > 0 then f.expected_base else 0 end,
    credit = case when coalesce(jl.credit, 0) > 0 then f.expected_base else 0 end,
    currency_code = f.currency_code,
    fx_rate = f.fx_rate,
    foreign_amount = f.expected_foreign
  from fixable f
  where jl.journal_entry_id = f.entry_id
    and (
      abs(coalesce(jl.debit, 0) - case when coalesce(jl.debit, 0) > 0 then f.expected_base else 0 end) > greatest(0.01, abs(coalesce(f.expected_base,0)) * 0.01)
      or abs(coalesce(jl.credit, 0) - case when coalesce(jl.credit, 0) > 0 then f.expected_base else 0 end) > greatest(0.01, abs(coalesce(f.expected_base,0)) * 0.01)
      or upper(coalesce(nullif(btrim(jl.currency_code), ''), '')) is distinct from f.currency_code
      or coalesce(jl.fx_rate, 0) is distinct from f.fx_rate
    );

  update public.journal_entries je
  set
    currency_code = f.currency_code,
    fx_rate = f.fx_rate,
    foreign_amount = f.expected_foreign
  from candidates f
  where je.id = f.entry_id
    and (
      upper(coalesce(nullif(btrim(je.currency_code), ''), '')) is distinct from f.currency_code
      or coalesce(je.fx_rate, 0) is distinct from f.fx_rate
      or abs(coalesce(je.foreign_amount, 0) - coalesce(f.expected_foreign, 0)) > greatest(0.01, abs(coalesce(f.expected_foreign,0)) * 0.01)
    );

  alter table public.journal_lines enable trigger user;
  alter table public.journal_entries enable trigger user;
end $$;

notify pgrst, 'reload schema';

