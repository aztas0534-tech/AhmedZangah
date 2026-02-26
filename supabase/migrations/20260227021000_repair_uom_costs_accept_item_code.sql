set app.allow_ledger_ddl = '1';

create or replace function public.repair_inflated_uom_costs_by_trx_qty(
  p_item_id text default null,
  p_warehouse_id uuid default null,
  p_limit int default 200,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_input text;
  v_item_id text;
  v_wh uuid;
  v_limit int;
  v_candidates int := 0;
  v_pri_updated int := 0;
  v_batches_updated int := 0;
  v_movements_updated int := 0;
  v_sm_updated int := 0;
begin
  if auth.uid() is null then
    if current_user not in ('postgres','supabase_admin') then
      raise exception 'not authenticated';
    end if;
  else
    if not public.has_admin_permission('accounting.manage') then
      raise exception 'not allowed';
    end if;
  end if;

  v_item_input := nullif(btrim(coalesce(p_item_id, '')), '');
  v_item_id := v_item_input;

  -- Accept item "code" (like AF6B8A) by resolving to menu_items.id when possible.
  if v_item_input is not null and to_regclass('public.menu_items') is not null then
    select mi.id::text
    into v_item_id
    from public.menu_items mi
    where mi.id::text = v_item_input
       or nullif(btrim(coalesce(mi.barcode, '')), '') = v_item_input
       or nullif(btrim(coalesce(mi.data->>'itemNumber', mi.data->>'item_number', mi.data->>'code', mi.data->>'sku', '')), '') = v_item_input
    order by (mi.id::text = v_item_input) desc, (nullif(btrim(coalesce(mi.barcode, '')), '') = v_item_input) desc
    limit 1;
  end if;

  v_wh := coalesce(p_warehouse_id, public._resolve_default_warehouse_id());
  if v_wh is null then
    raise exception 'warehouse_id is required';
  end if;
  v_limit := greatest(1, least(coalesce(p_limit, 200), 2000));

  if to_regclass('public.batches') is null or to_regclass('public.inventory_movements') is null then
    raise exception 'batches/inventory_movements missing';
  end if;

  create temporary table if not exists tmp_fix_uom_costs(
    batch_id uuid primary key,
    item_id text,
    warehouse_id uuid,
    receipt_id uuid,
    factor numeric,
    old_unit_cost numeric,
    new_unit_cost numeric
  ) on commit drop;
  truncate table tmp_fix_uom_costs;

  insert into tmp_fix_uom_costs(batch_id, item_id, warehouse_id, receipt_id, factor, old_unit_cost, new_unit_cost)
  select
    b.id,
    b.item_id::text,
    b.warehouse_id,
    b.receipt_id,
    (coalesce(b.quantity_received, 0) / nullif(nullif(btrim(coalesce(b.data->>'trxQty','')), '')::numeric, 0)) as factor,
    coalesce(b.unit_cost, 0) as old_unit_cost,
    round(coalesce(b.unit_cost, 0) / nullif((coalesce(b.quantity_received, 0) / nullif(nullif(btrim(coalesce(b.data->>'trxQty','')), '')::numeric, 0)), 0), 6) as new_unit_cost
  from public.batches b
  left join public.menu_items mi on mi.id::text = b.item_id::text
  where b.warehouse_id = v_wh
    and (v_item_input is null or b.item_id::text = v_item_id)
    and b.receipt_id is not null
    and nullif(btrim(coalesce(b.data->>'trxQty','')), '') is not null
    and coalesce(b.quantity_received, 0) > 0
    and coalesce(b.unit_cost, 0) > 0
    and (coalesce(b.quantity_received, 0) / nullif(nullif(btrim(coalesce(b.data->>'trxQty','')), '')::numeric, 0)) > 1.0001
    and round(coalesce(b.unit_cost, 0) / nullif((coalesce(b.quantity_received, 0) / nullif(nullif(btrim(coalesce(b.data->>'trxQty','')), '')::numeric, 0)), 0), 6) > 0
    and (
      coalesce(b.unit_cost, 0) >= 100
      or (coalesce(mi.price, 0) > 0 and coalesce(b.unit_cost, 0) > (mi.price * 5))
    )
  order by b.created_at desc
  limit v_limit;

  get diagnostics v_candidates = row_count;

  if coalesce(p_dry_run, true) then
    return jsonb_build_object(
      'warehouseId', v_wh::text,
      'itemInput', v_item_input,
      'resolvedItemId', v_item_id,
      'dryRun', true,
      'candidates', coalesce(v_candidates, 0)
    );
  end if;

  perform set_config('app.allow_ledger_ddl', '1', true);

  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_forbid_modify_posted;
  end if;

  if to_regclass('public.purchase_receipt_items') is not null then
    update public.purchase_receipt_items pri
    set
      unit_cost = t.new_unit_cost,
      total_cost = round(coalesce(pri.quantity, 0) * round(t.new_unit_cost, 6), 6)
    from tmp_fix_uom_costs t
    where pri.receipt_id = t.receipt_id
      and pri.item_id::text = t.item_id::text
      and coalesce(pri.unit_cost, 0) > 0
      and abs(coalesce(pri.unit_cost, 0) - coalesce(t.old_unit_cost, 0))
          <= greatest(0.01, abs(coalesce(t.old_unit_cost, 0)) * 0.05);

    get diagnostics v_pri_updated = row_count;
  end if;

  update public.batches b
  set
    unit_cost = t.new_unit_cost,
    updated_at = now()
  from tmp_fix_uom_costs t
  where b.id = t.batch_id;
  get diagnostics v_batches_updated = row_count;

  update public.inventory_movements im
  set
    unit_cost = t.new_unit_cost,
    total_cost = round(coalesce(im.quantity, 0) * round(t.new_unit_cost, 6), 6)
  from tmp_fix_uom_costs t
  where im.batch_id = t.batch_id
    and im.movement_type = 'purchase_in';
  get diagnostics v_movements_updated = row_count;

  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted;
  end if;

  if to_regclass('public.stock_management') is not null then
    with affected as (
      select distinct item_id, warehouse_id from tmp_fix_uom_costs
    ),
    calc as (
      select
        b.item_id::text as item_id,
        b.warehouse_id,
        sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) * coalesce(b.unit_cost, 0))
          / nullif(sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)), 0) as avg_cost
      from public.batches b
      join affected a on a.item_id = b.item_id::text and a.warehouse_id = b.warehouse_id
      where coalesce(b.status,'active') = 'active'
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

    get diagnostics v_sm_updated = row_count;
  end if;

  notify pgrst, 'reload schema';

  return jsonb_build_object(
    'warehouseId', v_wh::text,
    'itemInput', v_item_input,
    'resolvedItemId', v_item_id,
    'dryRun', false,
    'candidates', coalesce(v_candidates, 0),
    'receiptItemsUpdated', coalesce(v_pri_updated, 0),
    'batchesUpdated', coalesce(v_batches_updated, 0),
    'purchaseInMovementsUpdated', coalesce(v_movements_updated, 0),
    'stockAvgCostUpdated', coalesce(v_sm_updated, 0)
  );
end;
$$;

revoke all on function public.repair_inflated_uom_costs_by_trx_qty(text, uuid, int, boolean) from public;
grant execute on function public.repair_inflated_uom_costs_by_trx_qty(text, uuid, int, boolean) to authenticated;

notify pgrst, 'reload schema';
