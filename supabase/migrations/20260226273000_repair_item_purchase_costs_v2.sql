set app.allow_ledger_ddl = '1';

create or replace function public.repair_item_purchase_costs(
  p_item_id text,
  p_warehouse_id uuid default null,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_id text;
  v_wh uuid;
  v_base text;
  v_pri_updated int := 0;
  v_batches_updated int := 0;
  v_movements_updated int := 0;
  v_sm_updated int := 0;
  v_mi_updated int := 0;
  v_has_batch_lock_trigger boolean := false;
  v_has_pi_cost_cols boolean := false;
begin
  if not public.has_admin_permission('accounting.manage') then
    raise exception 'فشل إصلاح تكلفة الصنف: لا تملك صلاحية المحاسبة.';
  end if;

  v_item_id := nullif(btrim(coalesce(p_item_id, '')), '');
  if v_item_id is null then
    raise exception 'فشل إصلاح تكلفة الصنف: item_id مطلوب.';
  end if;

  v_wh := coalesce(p_warehouse_id, public._resolve_default_warehouse_id());
  if v_wh is null then
    raise exception 'فشل إصلاح تكلفة الصنف: warehouse_id مطلوب.';
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  if to_regclass('public.purchase_orders') is null
     or to_regclass('public.purchase_items') is null
     or to_regclass('public.purchase_receipts') is null
     or to_regclass('public.purchase_receipt_items') is null
     or to_regclass('public.batches') is null
     or to_regclass('public.inventory_movements') is null
     or to_regclass('public.stock_management') is null then
    raise exception 'فشل إصلاح تكلفة الصنف: جداول المشتريات/المخزون غير موجودة.';
  end if;

  select exists(
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'purchase_items'
      and column_name in ('unit_cost_base','unit_cost_foreign')
    group by table_schema, table_name
    having count(*) = 2
  ) into v_has_pi_cost_cols;

  if not v_has_pi_cost_cols then
    raise exception 'فشل إصلاح تكلفة الصنف: أعمدة unit_cost_base/unit_cost_foreign غير موجودة على purchase_items.';
  end if;

  if coalesce(p_dry_run, true) then
    with pi_avg as (
      select
        pr.id as receipt_id,
        b.item_id::text as item_id,
        case
          when sum(coalesce(pi.qty_base, 0)) > 0 then
            sum(
              coalesce(pi.qty_base, 0)
              * coalesce(
                  nullif(pi.unit_cost_base, 0),
                  case
                    when upper(coalesce(po.currency, v_base)) = v_base then nullif(pi.unit_cost_foreign, 0)
                    else round(nullif(pi.unit_cost_foreign, 0) * coalesce(nullif(po.fx_rate, 0), 1), 6)
                  end,
                  0
                )
            ) / sum(coalesce(pi.qty_base, 0))
          else
            max(
              coalesce(
                nullif(pi.unit_cost_base, 0),
                case
                  when upper(coalesce(po.currency, v_base)) = v_base then nullif(pi.unit_cost_foreign, 0)
                  else round(nullif(pi.unit_cost_foreign, 0) * coalesce(nullif(po.fx_rate, 0), 1), 6)
                end,
                0
              )
            )
        end as goods_unit_cost_base
      from public.batches b
      join public.purchase_receipts pr on pr.id = b.receipt_id
      join public.purchase_orders po on po.id = pr.purchase_order_id
      join public.purchase_items pi on pi.purchase_order_id = pr.purchase_order_id and pi.item_id::text = b.item_id::text
      where b.item_id::text = v_item_id
        and b.warehouse_id = v_wh
        and b.receipt_id is not null
      group by pr.id, b.item_id::text
    ),
    pri_fix as (
      select
        pri.id as pri_id,
        pri.receipt_id,
        pri.item_id::text as item_id,
        (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_unit_cost_base
      from public.purchase_receipt_items pri
      join pi_avg avg on avg.receipt_id = pri.receipt_id and avg.item_id = pri.item_id::text
      where pri.item_id::text = v_item_id
    )
    select jsonb_build_object(
      'warehouseId', v_wh::text,
      'itemId', v_item_id,
      'dryRun', true,
      'receiptItemsNeedingFix',
        coalesce((
          select count(1)
          from pri_fix f
          join public.purchase_receipt_items pri2 on pri2.id = f.pri_id
          where abs(coalesce(pri2.unit_cost, 0) - coalesce(f.expected_unit_cost_base, 0))
            > greatest(0.01, abs(coalesce(f.expected_unit_cost_base, 0)) * 0.05)
        ), 0),
      'batchesNeedingFix',
        coalesce((
          select count(1)
          from public.batches b2
          join public.purchase_receipt_items pri2 on pri2.receipt_id = b2.receipt_id and pri2.item_id::text = b2.item_id::text
          where b2.item_id::text = v_item_id
            and b2.warehouse_id = v_wh
            and abs(coalesce(b2.unit_cost, 0) - coalesce(pri2.unit_cost, 0))
              > greatest(0.01, abs(coalesce(pri2.unit_cost, 0)) * 0.05)
        ), 0)
    );
  end if;

  perform set_config('app.allow_ledger_ddl', '1', true);

  v_has_batch_lock_trigger := exists(
    select 1
    from pg_trigger t
    where t.tgname = 'trg_lock_batch_foreign_snapshot'
      and t.tgrelid = 'public.batches'::regclass
      and not t.tgisinternal
  );

  begin
    if v_has_batch_lock_trigger then
      execute 'alter table public.batches disable trigger trg_lock_batch_foreign_snapshot';
    end if;

    with pi_avg as (
      select
        pr.id as receipt_id,
        b.item_id::text as item_id,
        case
          when sum(coalesce(pi.qty_base, 0)) > 0 then
            sum(
              coalesce(pi.qty_base, 0)
              * coalesce(
                  nullif(pi.unit_cost_base, 0),
                  case
                    when upper(coalesce(po.currency, v_base)) = v_base then nullif(pi.unit_cost_foreign, 0)
                    else round(nullif(pi.unit_cost_foreign, 0) * coalesce(nullif(po.fx_rate, 0), 1), 6)
                  end,
                  0
                )
            ) / sum(coalesce(pi.qty_base, 0))
          else
            max(
              coalesce(
                nullif(pi.unit_cost_base, 0),
                case
                  when upper(coalesce(po.currency, v_base)) = v_base then nullif(pi.unit_cost_foreign, 0)
                  else round(nullif(pi.unit_cost_foreign, 0) * coalesce(nullif(po.fx_rate, 0), 1), 6)
                end,
                0
              )
            )
        end as goods_unit_cost_base
      from public.batches b
      join public.purchase_receipts pr on pr.id = b.receipt_id
      join public.purchase_orders po on po.id = pr.purchase_order_id
      join public.purchase_items pi on pi.purchase_order_id = pr.purchase_order_id and pi.item_id::text = b.item_id::text
      where b.item_id::text = v_item_id
        and b.warehouse_id = v_wh
        and b.receipt_id is not null
      group by pr.id, b.item_id::text
    ),
    pri_candidates as (
      select
        pri.id as pri_id,
        pri.quantity,
        (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)) as expected_unit_cost_base
      from public.purchase_receipt_items pri
      join pi_avg avg on avg.receipt_id = pri.receipt_id and avg.item_id = pri.item_id::text
      where pri.item_id::text = v_item_id
        and coalesce(pri.quantity, 0) > 0
        and coalesce(avg.goods_unit_cost_base, 0) > 0
        and abs(coalesce(pri.unit_cost, 0) - (avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0)))
          > greatest(0.01, abs((avg.goods_unit_cost_base + coalesce(pri.transport_cost, 0) + coalesce(pri.supply_tax_cost, 0))) * 0.05)
    )
    update public.purchase_receipt_items pri
    set
      unit_cost = round(c.expected_unit_cost_base, 6),
      total_cost = round(coalesce(c.quantity, 0) * round(c.expected_unit_cost_base, 6), 6)
    from pri_candidates c
    where pri.id = c.pri_id;

    get diagnostics v_pri_updated = row_count;

    update public.batches b
    set
      unit_cost = round(pri.unit_cost, 6),
      updated_at = now()
    from public.purchase_receipt_items pri
    where b.item_id::text = v_item_id
      and b.warehouse_id = v_wh
      and b.receipt_id is not null
      and pri.receipt_id = b.receipt_id
      and pri.item_id::text = b.item_id::text
      and coalesce(pri.unit_cost, 0) > 0
      and abs(coalesce(b.unit_cost, 0) - coalesce(pri.unit_cost, 0))
        > greatest(0.01, abs(coalesce(pri.unit_cost, 0)) * 0.05);

    get diagnostics v_batches_updated = row_count;

    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
      alter table public.inventory_movements disable trigger trg_inventory_movements_purchase_in_immutable;
    end if;
    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
      alter table public.inventory_movements disable trigger trg_inventory_movements_forbid_modify_posted;
    end if;

    begin
      update public.inventory_movements im
      set
        unit_cost = round(coalesce(b.unit_cost, 0), 6),
        total_cost = round(coalesce(im.quantity, 0) * round(coalesce(b.unit_cost, 0), 6), 6)
      from public.batches b
      where im.movement_type = 'purchase_in'
        and im.batch_id = b.id
        and b.item_id::text = v_item_id
        and b.warehouse_id = v_wh
        and abs(coalesce(im.unit_cost, 0) - coalesce(b.unit_cost, 0))
          > greatest(0.01, abs(coalesce(b.unit_cost, 0)) * 0.05);

      get diagnostics v_movements_updated = row_count;
    exception when others then
      v_movements_updated := 0;
    end;

    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
      alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable;
    end if;
    if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
      alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted;
    end if;

    with calc as (
      select
        b.item_id::text as item_id,
        b.warehouse_id,
        sum(
          greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) * coalesce(b.unit_cost, 0)
        ) / nullif(
          sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)),
          0
        ) as avg_cost
      from public.batches b
      where b.item_id::text = v_item_id
        and b.warehouse_id = v_wh
        and coalesce(b.status, 'active') = 'active'
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
      and sm.warehouse_id = c.warehouse_id
      and abs(coalesce(sm.avg_cost, 0) - coalesce(c.avg_cost, 0)) > 0.000001;

    get diagnostics v_sm_updated = row_count;

    update public.menu_items mi
    set
      cost_price = sm.avg_cost,
      updated_at = now()
    from public.stock_management sm
    where mi.id::text = v_item_id
      and sm.item_id::text = v_item_id
      and sm.warehouse_id = v_wh
      and coalesce(sm.avg_cost, 0) > 0
      and abs(coalesce(mi.cost_price, 0) - coalesce(sm.avg_cost, 0)) > 0.000001;

    get diagnostics v_mi_updated = row_count;
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
    raise exception 'فشل إصلاح تكلفة الصنف: %', sqlerrm;
  end;

  if v_has_batch_lock_trigger then
    execute 'alter table public.batches enable trigger trg_lock_batch_foreign_snapshot';
  end if;

  notify pgrst, 'reload schema';

  return jsonb_build_object(
    'warehouseId', v_wh::text,
    'itemId', v_item_id,
    'dryRun', false,
    'receiptItemsUpdated', coalesce(v_pri_updated, 0),
    'batchesUpdated', coalesce(v_batches_updated, 0),
    'purchaseInMovementsUpdated', coalesce(v_movements_updated, 0),
    'stockAvgCostUpdated', coalesce(v_sm_updated, 0),
    'menuItemCostUpdated', coalesce(v_mi_updated, 0)
  );
end;
$$;

revoke all on function public.repair_item_purchase_costs(text, uuid, boolean) from public;
grant execute on function public.repair_item_purchase_costs(text, uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
