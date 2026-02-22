set app.allow_ledger_ddl = '1';

do $$
declare
  v_base text;
  v_has_batch_lock_trigger boolean := false;
begin
  if to_regclass('public.purchase_items') is null
     or to_regclass('public.purchase_receipt_items') is null
     or to_regclass('public.purchase_receipts') is null
     or to_regclass('public.purchase_orders') is null
     or to_regclass('public.inventory_movements') is null
     or to_regclass('public.batches') is null then
    return;
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  v_has_batch_lock_trigger := exists(
    select 1 from pg_trigger where tgname = 'trg_lock_batch_foreign_snapshot'
  );
  if v_has_batch_lock_trigger then
    execute 'alter table public.batches disable trigger trg_lock_batch_foreign_snapshot';
  end if;

  begin
    with pi_avg as (
      select
        pi.purchase_order_id,
        pi.item_id,
        case
          when sum(coalesce(pi.qty_base, 0)) > 0
            then sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
          else max(coalesce(pi.unit_cost_base, 0))
        end as goods_unit_cost_base
      from public.purchase_items pi
      group by pi.purchase_order_id, pi.item_id
    ),
    pri_fix as (
      select
        pri.id as pri_id,
        pri.quantity,
        pri.unit_cost as current_unit_cost,
        pri.transport_cost,
        pri.supply_tax_cost,
        (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_unit_cost_base
      from public.purchase_receipt_items pri
      join public.purchase_receipts pr on pr.id = pri.receipt_id
      join public.purchase_orders po on po.id = pr.purchase_order_id
      join pi_avg avg on avg.purchase_order_id = pr.purchase_order_id and avg.item_id = pri.item_id
      where upper(coalesce(po.currency, v_base)) = v_base
        and coalesce(avg.goods_unit_cost_base, 0) > 0
        and coalesce(pri.quantity, 0) > 0
    ),
    pri_candidates as (
      select
        pri_id,
        expected_unit_cost_base,
        (coalesce(quantity, 0) * coalesce(expected_unit_cost_base, 0)) as expected_total_cost
      from pri_fix
      where abs(coalesce(current_unit_cost, 0) - coalesce(expected_unit_cost_base, 0))
        > greatest(0.01, abs(coalesce(expected_unit_cost_base, 0)) * 0.05)
    )
    update public.purchase_receipt_items pri
    set
      unit_cost = round(c.expected_unit_cost_base, 6),
      total_cost = round(c.expected_total_cost, 6)
    from pri_candidates c
    where pri.id = c.pri_id;

    with pi_avg as (
      select
        pi.purchase_order_id,
        pi.item_id,
        case
          when sum(coalesce(pi.qty_base, 0)) > 0
            then sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
          else max(coalesce(pi.unit_cost_base, 0))
        end as goods_unit_cost_base
      from public.purchase_items pi
      group by pi.purchase_order_id, pi.item_id
    ),
    b_fix as (
      select
        b.id as batch_id,
        b.unit_cost as current_unit_cost,
        (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_unit_cost_base
      from public.batches b
      join public.purchase_receipts pr on pr.id = b.receipt_id
      join public.purchase_orders po on po.id = pr.purchase_order_id
      left join public.purchase_receipt_items pri on pri.receipt_id = b.receipt_id and pri.item_id = b.item_id
      join pi_avg avg on avg.purchase_order_id = pr.purchase_order_id and avg.item_id = b.item_id
      where upper(coalesce(po.currency, v_base)) = v_base
        and coalesce(b.status, 'active') = 'active'
        and coalesce(avg.goods_unit_cost_base, 0) > 0
        and coalesce(b.quantity_received, 0) > 0
    ),
    b_candidates as (
      select
        batch_id,
        expected_unit_cost_base
      from b_fix
      where abs(coalesce(current_unit_cost, 0) - coalesce(expected_unit_cost_base, 0))
        > greatest(0.01, abs(coalesce(expected_unit_cost_base, 0)) * 0.05)
    )
    update public.batches b
    set
      unit_cost = round(c.expected_unit_cost_base, 6),
      updated_at = now()
    from b_candidates c
    where b.id = c.batch_id;

    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
      alter table public.inventory_movements disable trigger trg_inventory_movements_purchase_in_immutable;
    end if;
    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
      alter table public.inventory_movements disable trigger trg_inventory_movements_forbid_modify_posted;
    end if;

    with pi_avg as (
      select
        pi.purchase_order_id,
        pi.item_id,
        case
          when sum(coalesce(pi.qty_base, 0)) > 0
            then sum(coalesce(pi.qty_base, 0) * coalesce(pi.unit_cost_base, 0)) / sum(coalesce(pi.qty_base, 0))
          else max(coalesce(pi.unit_cost_base, 0))
        end as goods_unit_cost_base
      from public.purchase_items pi
      group by pi.purchase_order_id, pi.item_id
    ),
    b_fix as (
      select
        b.id as batch_id,
        (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_unit_cost_base
      from public.batches b
      join public.purchase_receipts pr on pr.id = b.receipt_id
      join public.purchase_orders po on po.id = pr.purchase_order_id
      left join public.purchase_receipt_items pri on pri.receipt_id = b.receipt_id and pri.item_id = b.item_id
      join pi_avg avg on avg.purchase_order_id = pr.purchase_order_id and avg.item_id = b.item_id
      where upper(coalesce(po.currency, v_base)) = v_base
        and coalesce(b.status, 'active') = 'active'
        and coalesce(avg.goods_unit_cost_base, 0) > 0
        and coalesce(b.quantity_received, 0) > 0
    )
    update public.inventory_movements im
    set
      unit_cost = round(bf.expected_unit_cost_base, 6),
      total_cost = round(coalesce(im.quantity, 0) * round(bf.expected_unit_cost_base, 6), 6)
    from b_fix bf
    where im.batch_id = bf.batch_id
      and im.movement_type = 'purchase_in'
      and abs(coalesce(im.unit_cost, 0) - coalesce(bf.expected_unit_cost_base, 0))
        > greatest(0.01, abs(coalesce(bf.expected_unit_cost_base, 0)) * 0.05);

    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
      alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable;
    end if;
    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
      alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted;
    end if;
  exception when others then
    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
      alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable;
    end if;
    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
      alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted;
    end if;
    if v_has_batch_lock_trigger then
      execute 'alter table public.batches enable trigger trg_lock_batch_foreign_snapshot';
    end if;
    raise;
  end;

  if v_has_batch_lock_trigger then
    execute 'alter table public.batches enable trigger trg_lock_batch_foreign_snapshot';
  end if;
end $$;

notify pgrst, 'reload schema';
