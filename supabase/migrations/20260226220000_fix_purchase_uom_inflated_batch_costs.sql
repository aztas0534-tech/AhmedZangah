set app.allow_ledger_ddl = '1';

do $$
declare
  v_base text;
begin
  if to_regclass('public.purchase_orders') is null
     or to_regclass('public.purchase_items') is null
     or to_regclass('public.purchase_receipts') is null
     or to_regclass('public.purchase_receipt_items') is null
     or to_regclass('public.batches') is null
     or to_regclass('public.inventory_movements') is null
     or to_regclass('public.stock_management') is null then
    return;
  end if;

  v_base := upper(coalesce(public.get_base_currency(), ''));
  if v_base = '' then
    v_base := 'SAR';
  end if;

  create temporary table tmp_fixed_batches(
    batch_id uuid primary key,
    item_id text not null,
    warehouse_id uuid not null
  ) on commit drop;

  update public.purchase_items pi
  set
    qty_base = public.item_qty_to_base(pi.item_id, coalesce(pi.quantity, 0), pi.uom_id),
    unit_cost_foreign = public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost_foreign, pi.unit_cost, 0), pi.uom_id),
    unit_cost_base =
      case
        when upper(coalesce(po.currency, v_base)) = v_base then
          public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost_foreign, pi.unit_cost, 0), pi.uom_id)
        else
          round(
            public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost_foreign, pi.unit_cost, 0), pi.uom_id)
            * coalesce(nullif(po.fx_rate, 0), 1),
            6
          )
      end
  from public.purchase_orders po
  where po.id = pi.purchase_order_id
    and pi.uom_id is not null
    and (
      pi.qty_base is null
      or abs(
        coalesce(pi.qty_base, 0)
        - public.item_qty_to_base(pi.item_id, coalesce(pi.quantity, 0), pi.uom_id)
      ) > greatest(
        0.01,
        abs(public.item_qty_to_base(pi.item_id, coalesce(pi.quantity, 0), pi.uom_id)) * 0.01
      )
      or pi.unit_cost_base is null
      or pi.unit_cost_base = 0
      or (upper(coalesce(po.currency, v_base)) <> v_base and (pi.unit_cost_foreign is null or pi.unit_cost_foreign = 0))
    );

  with pi_avg as (
    select
      pi.purchase_order_id,
      pi.item_id::text as item_id,
      upper(coalesce(po.currency, v_base)) as po_currency,
      coalesce(nullif(po.fx_rate, 0), 1) as fx_rate,
      case
        when sum(coalesce(pi.qty_base, 0)) > 0 then
          sum(coalesce(pi.qty_base, 0) * coalesce(nullif(pi.unit_cost_foreign, 0), public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost, 0), pi.uom_id), 0))
          / sum(coalesce(pi.qty_base, 0))
        else
          max(coalesce(nullif(pi.unit_cost_foreign, 0), public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost, 0), pi.uom_id), 0))
      end as goods_unit_cost_foreign,
      case
        when upper(coalesce(po.currency, v_base)) = v_base then
          (case
            when sum(coalesce(pi.qty_base, 0)) > 0 then
              sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
            else
              max(coalesce(pi.unit_cost_base, 0))
          end)
        else
          round(
            (case
              when sum(coalesce(pi.qty_base, 0)) > 0 then
                sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
              else
                max(coalesce(pi.unit_cost_base, 0))
            end) * coalesce(nullif(po.fx_rate, 0), 1),
            6
          )
      end as goods_unit_cost_base
    from public.purchase_items pi
    join public.purchase_orders po on po.id = pi.purchase_order_id
    group by pi.purchase_order_id, pi.item_id::text, upper(coalesce(po.currency, v_base)), coalesce(nullif(po.fx_rate, 0), 1)
  ),
  cand as (
    select
      b.id as batch_id,
      b.receipt_id,
      b.warehouse_id,
      b.item_id::text as item_id,
      coalesce(b.quantity_received, 0) as qty_base,
      nullif(btrim(coalesce(b.data->>'trxQty', '')), '')::numeric as trx_qty,
      case
        when nullif(btrim(coalesce(b.data->>'trxQty', '')), '') is null then null
        else coalesce(b.quantity_received, 0) / nullif(nullif(btrim(coalesce(b.data->>'trxQty', '')), '')::numeric, 0)
      end as factor,
      coalesce(pri.transport_cost, 0) as transport_cost,
      coalesce(pri.supply_tax_cost, 0) as supply_tax_cost,
      coalesce(b.unit_cost, 0) as current_unit_cost,
      coalesce(b.foreign_unit_cost, 0) as current_foreign_unit_cost,
      b.foreign_currency,
      coalesce(nullif(b.fx_rate_at_receipt, 0), nullif(po.fx_rate, 0), 1) as fx_rate_at_receipt,
      avg.goods_unit_cost_foreign,
      avg.goods_unit_cost_base,
      (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_effective_base
    from public.batches b
    join public.purchase_receipts pr on pr.id = b.receipt_id
    join public.purchase_orders po on po.id = pr.purchase_order_id
    left join public.purchase_receipt_items pri
      on pri.receipt_id = b.receipt_id
      and pri.item_id::text = b.item_id::text
    join pi_avg avg
      on avg.purchase_order_id = pr.purchase_order_id
      and avg.item_id = b.item_id::text
    where b.receipt_id is not null
      and coalesce(b.quantity_received, 0) > 0
      and nullif(btrim(coalesce(b.data->>'trxQty', '')), '') is not null
  ),
  fix as (
    select *
    from cand
    where trx_qty > 0
      and factor is not null
      and factor > 1.0001
      and expected_effective_base > 0
      and abs(current_unit_cost - (expected_effective_base * factor))
          <= greatest(0.01, abs(expected_effective_base * factor) * 0.02)
      and abs(current_unit_cost - expected_effective_base)
          > greatest(0.01, abs(expected_effective_base) * 0.02)
  )
  , upd as (
    update public.batches b
    set
      unit_cost = round(f.expected_effective_base, 6),
      foreign_unit_cost =
        case
          when b.foreign_currency is null then b.foreign_unit_cost
          when abs(coalesce(b.foreign_unit_cost, 0) - (coalesce(f.goods_unit_cost_foreign, 0) * coalesce(f.factor, 1)))
              <= greatest(0.01, abs(coalesce(f.goods_unit_cost_foreign, 0) * coalesce(f.factor, 1)) * 0.02)
            then round(coalesce(f.goods_unit_cost_foreign, 0), 6)
          else b.foreign_unit_cost
        end,
      updated_at = now()
    from fix f
    where b.id = f.batch_id
    returning b.id as batch_id, b.item_id::text as item_id, b.warehouse_id
  )
  insert into tmp_fixed_batches(batch_id, item_id, warehouse_id)
  select batch_id, item_id, warehouse_id
  from upd
  on conflict (batch_id) do nothing;

  with pi_avg as (
    select
      pi.purchase_order_id,
      pi.item_id::text as item_id,
      upper(coalesce(po.currency, v_base)) as po_currency,
      coalesce(nullif(po.fx_rate, 0), 1) as fx_rate,
      case
        when sum(coalesce(pi.qty_base, 0)) > 0 then
          sum(coalesce(pi.qty_base, 0) * coalesce(nullif(pi.unit_cost_foreign, 0), public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost, 0), pi.uom_id), 0))
          / sum(coalesce(pi.qty_base, 0))
        else
          max(coalesce(nullif(pi.unit_cost_foreign, 0), public.item_unit_cost_to_base(pi.item_id, coalesce(pi.unit_cost, 0), pi.uom_id), 0))
      end as goods_unit_cost_foreign,
      case
        when upper(coalesce(po.currency, v_base)) = v_base then
          (case
            when sum(coalesce(pi.qty_base, 0)) > 0 then
              sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
            else
              max(coalesce(pi.unit_cost_base, 0))
          end)
        else
          round(
            (case
              when sum(coalesce(pi.qty_base, 0)) > 0 then
                sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
              else
                max(coalesce(pi.unit_cost_base, 0))
            end) * coalesce(nullif(po.fx_rate, 0), 1),
            6
          )
      end as goods_unit_cost_base
    from public.purchase_items pi
    join public.purchase_orders po on po.id = pi.purchase_order_id
    group by pi.purchase_order_id, pi.item_id::text, upper(coalesce(po.currency, v_base)), coalesce(nullif(po.fx_rate, 0), 1)
  ),
  cand as (
    select
      b.id as batch_id,
      b.receipt_id,
      b.warehouse_id,
      b.item_id::text as item_id,
      coalesce(b.quantity_received, 0) as qty_base,
      nullif(btrim(coalesce(b.data->>'trxQty', '')), '')::numeric as trx_qty,
      case
        when nullif(btrim(coalesce(b.data->>'trxQty', '')), '') is null then null
        else coalesce(b.quantity_received, 0) / nullif(nullif(btrim(coalesce(b.data->>'trxQty', '')), '')::numeric, 0)
      end as factor,
      coalesce(pri.transport_cost, 0) as transport_cost,
      coalesce(pri.supply_tax_cost, 0) as supply_tax_cost,
      coalesce(pri.unit_cost, 0) as pri_unit_cost,
      coalesce(pri.total_cost, 0) as pri_total_cost,
      coalesce(b.unit_cost, 0) as b_unit_cost,
      avg.goods_unit_cost_base,
      (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_effective_base
    from public.batches b
    join public.purchase_receipts pr on pr.id = b.receipt_id
    join pi_avg avg on avg.purchase_order_id = pr.purchase_order_id and avg.item_id = b.item_id::text
    join public.purchase_receipt_items pri on pri.receipt_id = b.receipt_id and pri.item_id::text = b.item_id::text
    where b.receipt_id is not null
      and coalesce(b.quantity_received, 0) > 0
      and nullif(btrim(coalesce(b.data->>'trxQty', '')), '') is not null
  ),
  fix as (
    select *
    from cand
    where trx_qty > 0
      and factor is not null
      and factor > 1.0001
      and expected_effective_base > 0
      and abs(pri_unit_cost - (expected_effective_base * factor))
          <= greatest(0.01, abs(expected_effective_base * factor) * 0.02)
  )
  update public.purchase_receipt_items pri
  set
    unit_cost = round(f.expected_effective_base, 6),
    total_cost = round(coalesce(pri.quantity, 0) * round(f.expected_effective_base, 6), 6)
  from fix f
  where pri.receipt_id = f.receipt_id
    and pri.item_id::text = f.item_id
    and exists (select 1 from tmp_fixed_batches t where t.batch_id = f.batch_id);

  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_forbid_modify_posted;
  end if;

  begin
    with pi_avg as (
      select
        pi.purchase_order_id,
        pi.item_id::text as item_id,
        case
          when upper(coalesce(po.currency, v_base)) = v_base then
            (case
              when sum(coalesce(pi.qty_base, 0)) > 0 then
                sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
              else
                max(coalesce(pi.unit_cost_base, 0))
            end)
          else
            round(
              (case
                when sum(coalesce(pi.qty_base, 0)) > 0 then
                  sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
                else
                  max(coalesce(pi.unit_cost_base, 0))
              end) * coalesce(nullif(po.fx_rate, 0), 1),
              6
            )
        end as goods_unit_cost_base
      from public.purchase_items pi
      join public.purchase_orders po on po.id = pi.purchase_order_id
      group by pi.purchase_order_id, pi.item_id::text, upper(coalesce(po.currency, v_base)), coalesce(nullif(po.fx_rate, 0), 1)
    ),
    cand as (
      select
        b.id as batch_id,
        b.receipt_id,
        b.warehouse_id,
        b.item_id::text as item_id,
        coalesce(im.quantity, 0) as qty_base,
        nullif(btrim(coalesce(b.data->>'trxQty', '')), '')::numeric as trx_qty,
        case
          when nullif(btrim(coalesce(b.data->>'trxQty', '')), '') is null then null
          else coalesce(im.quantity, 0) / nullif(nullif(btrim(coalesce(b.data->>'trxQty', '')), '')::numeric, 0)
        end as factor,
        coalesce(pri.transport_cost, 0) as transport_cost,
        coalesce(pri.supply_tax_cost, 0) as supply_tax_cost,
        coalesce(im.unit_cost, 0) as im_unit_cost,
        avg.goods_unit_cost_base,
        (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_effective_base
      from public.inventory_movements im
      join public.batches b on b.id = im.batch_id
      join public.purchase_receipts pr on pr.id = b.receipt_id
      join pi_avg avg on avg.purchase_order_id = pr.purchase_order_id and avg.item_id = b.item_id::text
      join public.purchase_receipt_items pri on pri.receipt_id = b.receipt_id and pri.item_id::text = b.item_id::text
      where im.movement_type = 'purchase_in'
        and b.receipt_id is not null
        and coalesce(im.quantity, 0) > 0
        and nullif(btrim(coalesce(b.data->>'trxQty', '')), '') is not null
    ),
    fix as (
      select *
      from cand
      where trx_qty > 0
        and factor is not null
        and factor > 1.0001
        and expected_effective_base > 0
        and abs(im_unit_cost - (expected_effective_base * factor))
            <= greatest(0.01, abs(expected_effective_base * factor) * 0.02)
    )
    update public.inventory_movements im
    set
      unit_cost = round(f.expected_effective_base, 6),
      total_cost = round(coalesce(im.quantity, 0) * round(f.expected_effective_base, 6), 6)
    from fix f
    where im.batch_id = f.batch_id
      and im.movement_type = 'purchase_in'
      and exists (select 1 from tmp_fixed_batches t where t.batch_id = f.batch_id);
  exception when others then
    null;
  end;

  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted;
  end if;

  with affected as (
    select distinct t.item_id, t.warehouse_id
    from tmp_fixed_batches t
  ),
  calc as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) * coalesce(b.unit_cost, 0))
        / nullif(sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)), 0) as avg_cost
    from public.batches b
    join affected a on a.item_id = b.item_id::text and a.warehouse_id = b.warehouse_id
    where coalesce(b.status, 'active') = 'active'
      and greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) > 0
    group by b.item_id::text, b.warehouse_id
  )
  update public.stock_management sm
  set
    avg_cost = round(coalesce(c.avg_cost, sm.avg_cost), 6),
    updated_at = now(),
    last_updated = now()
  from calc c
  where sm.item_id::text = c.item_id
    and sm.warehouse_id = c.warehouse_id;
end $$;

notify pgrst, 'reload schema';

