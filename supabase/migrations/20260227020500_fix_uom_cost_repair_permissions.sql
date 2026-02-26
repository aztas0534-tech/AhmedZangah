set app.allow_ledger_ddl = '1';

-- Allow running emergency repair RPCs from Supabase SQL Editor (postgres/supabase_admin)
-- while still enforcing RBAC for normal authenticated sessions.

create or replace function public.normalize_batch_unit_cost_by_trx_qty(
  p_batch_id uuid,
  p_reason text,
  p_post_journal boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
  v_trx_qty numeric;
  v_factor numeric;
  v_old numeric;
  v_new numeric;
  v_price numeric;
  v_item_id text;
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

  if p_batch_id is null then
    raise exception 'p_batch_id is required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'reason is required';
  end if;

  select
    b.id,
    b.item_id::text as item_id,
    b.warehouse_id,
    coalesce(b.unit_cost, 0) as unit_cost,
    coalesce(b.quantity_received, 0) as quantity_received,
    b.data
  into v_b
  from public.batches b
  where b.id = p_batch_id
  for update;
  if not found then
    raise exception 'batch not found';
  end if;

  v_item_id := v_b.item_id;
  begin
    v_trx_qty := nullif(btrim(coalesce(v_b.data->>'trxQty', '')), '')::numeric;
  exception when others then
    v_trx_qty := null;
  end;

  if v_trx_qty is null or v_trx_qty <= 0 then
    raise exception 'trxQty missing on batch';
  end if;
  if coalesce(v_b.quantity_received, 0) <= 0 then
    raise exception 'quantity_received missing on batch';
  end if;

  v_factor := coalesce(v_b.quantity_received, 0) / nullif(v_trx_qty, 0);
  if v_factor is null or v_factor <= 1.0001 then
    raise exception 'no uom factor inferred';
  end if;

  select coalesce(mi.price, 0) into v_price
  from public.menu_items mi
  where mi.id::text = v_item_id
  limit 1;

  v_old := coalesce(v_b.unit_cost, 0);
  v_new := round(v_old / v_factor, 6);
  if v_new <= 0 then
    raise exception 'computed unit cost invalid';
  end if;

  if v_old < 50 then
    raise exception 'unit_cost not high enough to normalize safely';
  end if;
  if coalesce(v_price, 0) > 0 and v_old <= (v_price * 5) then
    raise exception 'unit_cost not outlier vs selling price';
  end if;

  perform public.revalue_batch_unit_cost(p_batch_id, v_new, concat('normalize_by_trxQty: ', p_reason), coalesce(p_post_journal, true));
  return jsonb_build_object(
    'batchId', p_batch_id::text,
    'itemId', v_item_id,
    'oldUnitCost', v_old,
    'newUnitCost', v_new,
    'factor', v_factor,
    'trxQty', v_trx_qty,
    'qtyBase', coalesce(v_b.quantity_received, 0)
  );
end;
$$;

revoke all on function public.normalize_batch_unit_cost_by_trx_qty(uuid, text, boolean) from public;
grant execute on function public.normalize_batch_unit_cost_by_trx_qty(uuid, text, boolean) to authenticated;

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

  v_item_id := nullif(btrim(coalesce(p_item_id, '')), '');
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
    and (v_item_id is null or b.item_id::text = v_item_id)
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
      'itemId', v_item_id,
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
    'itemId', v_item_id,
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
