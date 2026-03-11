set app.allow_ledger_ddl = '1';

-- ===========================================================================
-- FIX 1: Repair inflated purchase_receipt_items.unit_cost
-- Problem: unit_cost is per-purchase-UOM (e.g. per carton = 147 SAR) but
--          quantity is in base units (e.g. pieces = 5088). This inflates FOB.
-- Fix: Divide unit_cost by the UOM conversion factor where factor > 1.
-- ===========================================================================

do $$
declare
  v_base text;
  v_fixed int := 0;
  v_batch_created int := 0;
  v_rec record;
  v_factor numeric;
  v_correct_unit_cost numeric;
  v_correct_total numeric;
  v_batch_id uuid;
  v_wh uuid;
begin
  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));

  -- Step 1: Fix inflated purchase_receipt_items.unit_cost
  for v_rec in
    select
      pri.id as pri_id,
      pri.receipt_id,
      pri.item_id,
      pri.quantity as pri_qty,
      pri.unit_cost as pri_unit_cost,
      pri.total_cost as pri_total_cost,
      pri.transport_cost,
      pri.supply_tax_cost,
      pi.uom_id,
      pi.unit_cost as po_unit_cost,
      coalesce(pi.qty_base, 0) as po_qty_base,
      coalesce(pi.quantity, 0) as po_qty_trx,
      po.currency as po_currency,
      coalesce(po.fx_rate, 1) as po_fx_rate,
      pr.warehouse_id,
      pr.import_shipment_id
    from public.purchase_receipt_items pri
    join public.purchase_receipts pr on pr.id = pri.receipt_id
    join public.purchase_orders po on po.id = pr.purchase_order_id
    join public.purchase_items pi
      on pi.purchase_order_id = po.id
      and pi.item_id::text = pri.item_id::text
    where pi.uom_id is not null
      and coalesce(pri.quantity, 0) > 0
  loop
    -- Get the UOM conversion factor
    begin
      select iuu.qty_in_base into v_factor
      from public.item_uom_units iuu
      where iuu.item_id = v_rec.item_id::text
        and iuu.uom_id = v_rec.uom_id
        and iuu.is_active = true
      limit 1;
    exception when others then
      v_factor := null;
    end;

    -- Skip if no factor or factor = 1 (already base unit)
    if v_factor is null or v_factor <= 1 then
      continue;
    end if;

    -- Check if the unit_cost looks inflated:
    -- If unit_cost ≈ po_unit_cost (per-carton), it's inflated
    -- The correct unit_cost should be po_unit_cost / factor (per-piece)
    -- We also need to account for FX conversion and transport/tax costs
    
    -- Calculate what the base unit cost SHOULD be (goods cost only, no transport/tax)
    v_correct_unit_cost := coalesce(v_rec.po_unit_cost, 0) / v_factor;
    
    -- Apply FX if needed
    if upper(coalesce(v_rec.po_currency, v_base)) <> v_base and v_rec.po_fx_rate > 0 then
      v_correct_unit_cost := v_correct_unit_cost * v_rec.po_fx_rate;
    end if;
    
    -- Add transport and tax costs (these should already be per-base-unit)
    v_correct_unit_cost := v_correct_unit_cost 
      + coalesce(v_rec.transport_cost, 0) 
      + coalesce(v_rec.supply_tax_cost, 0);

    -- Only fix if the current cost is significantly different from the correct cost
    -- AND looks like it's inflated by the factor
    if abs(v_rec.pri_unit_cost - v_correct_unit_cost) > 0.01
       and v_rec.pri_unit_cost > v_correct_unit_cost * 1.5 then
      
      v_correct_total := v_rec.pri_qty * v_correct_unit_cost;

      update public.purchase_receipt_items
      set unit_cost = round(v_correct_unit_cost, 6),
          total_cost = round(v_correct_total, 6)
      where id = v_rec.pri_id;

      v_fixed := v_fixed + 1;

      -- Also fix the corresponding batch if exists
      update public.batches b
      set unit_cost = round(v_correct_unit_cost, 6),
          updated_at = now()
      where b.receipt_id = v_rec.receipt_id
        and b.item_id::text = v_rec.item_id::text
        and coalesce(b.unit_cost, 0) > v_correct_unit_cost * 1.5;

      -- Also fix inventory_movements
      begin
        if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
          execute 'alter table public.inventory_movements disable trigger trg_inventory_movements_purchase_in_immutable';
        end if;
        if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
          execute 'alter table public.inventory_movements disable trigger trg_inventory_movements_forbid_modify_posted';
        end if;
        
        update public.inventory_movements im
        set unit_cost = round(v_correct_unit_cost, 6),
            total_cost = round(coalesce(im.quantity, 0) * round(v_correct_unit_cost, 6), 6)
        where im.reference_table = 'purchase_receipts'
          and im.reference_id = v_rec.receipt_id::text
          and im.item_id::text = v_rec.item_id::text
          and im.movement_type = 'purchase_in'
          and coalesce(im.unit_cost, 0) > v_correct_unit_cost * 1.5;
        
        if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
          execute 'alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable';
        end if;
        if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
          execute 'alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted';
        end if;
      exception when others then
        null; -- don't block if triggers don't exist
      end;
    end if;
  end loop;

  raise notice 'Fixed % inflated purchase_receipt_items', v_fixed;

  -- Step 2: Create missing batches for receipts that don't have batches
  for v_rec in
    select
      pri.id as pri_id,
      pri.receipt_id,
      pri.item_id,
      pri.quantity,
      pri.unit_cost,
      pri.transport_cost,
      pri.supply_tax_cost,
      pr.warehouse_id,
      pr.purchase_order_id,
      pr.received_at,
      pr.created_by,
      pr.import_shipment_id,
      po.currency as po_currency,
      coalesce(po.fx_rate, 1) as po_fx_rate
    from public.purchase_receipt_items pri
    join public.purchase_receipts pr on pr.id = pri.receipt_id
    join public.purchase_orders po on po.id = pr.purchase_order_id
    where coalesce(pri.quantity, 0) > 0
      and not exists (
        select 1 from public.batches b
        where b.receipt_id = pri.receipt_id
          and b.item_id::text = pri.item_id::text
      )
  loop
    v_wh := v_rec.warehouse_id;

    -- Insert batch
    insert into public.batches(
      id, item_id, receipt_item_id, receipt_id, warehouse_id,
      batch_code, production_date, expiry_date,
      quantity_received, quantity_consumed, quantity_transferred,
      unit_cost, qc_status, status,
      foreign_currency, foreign_unit_cost, fx_rate_at_receipt,
      data
    ) values (
      gen_random_uuid(), v_rec.item_id, v_rec.pri_id, v_rec.receipt_id, v_wh,
      null, null, null,
      v_rec.quantity, 0, 0,
      coalesce(v_rec.unit_cost, 0), 'released', 'active',
      case when upper(coalesce(v_rec.po_currency, v_base)) <> v_base then upper(v_rec.po_currency) else null end,
      case when upper(coalesce(v_rec.po_currency, v_base)) <> v_base then
        case when v_rec.po_fx_rate > 0 then coalesce(v_rec.unit_cost, 0) / v_rec.po_fx_rate else 0 end
      else null end,
      case when upper(coalesce(v_rec.po_currency, v_base)) <> v_base then v_rec.po_fx_rate else null end,
      jsonb_build_object(
        'purchaseOrderId', v_rec.purchase_order_id,
        'purchaseReceiptId', v_rec.receipt_id,
        'warehouseId', v_wh,
        'repairMigration', '20260301020000',
        'importShipmentId', case when v_rec.import_shipment_id is null then null else v_rec.import_shipment_id::text end
      )
    ) returning id into v_batch_id;

    -- Create inventory movement if missing
    if not exists (
      select 1 from public.inventory_movements im
      where im.reference_table = 'purchase_receipts'
        and im.reference_id = v_rec.receipt_id::text
        and im.item_id::text = v_rec.item_id::text
        and im.movement_type = 'purchase_in'
    ) then
      insert into public.inventory_movements(
        item_id, movement_type, quantity, unit_cost, total_cost,
        reference_table, reference_id, occurred_at, created_by,
        batch_id, warehouse_id,
        data
      ) values (
        v_rec.item_id, 'purchase_in', v_rec.quantity, coalesce(v_rec.unit_cost, 0),
        v_rec.quantity * coalesce(v_rec.unit_cost, 0),
        'purchase_receipts', v_rec.receipt_id::text,
        coalesce(v_rec.received_at, now()), v_rec.created_by,
        v_batch_id, v_wh,
        jsonb_build_object(
          'purchaseOrderId', v_rec.purchase_order_id,
          'purchaseReceiptId', v_rec.receipt_id,
          'batchId', v_batch_id,
          'repairMigration', '20260301020000'
        )
      );
    end if;

    -- Update stock_management for this item/warehouse
    insert into public.stock_management(item_id, warehouse_id, available_quantity, qc_hold_quantity, reserved_quantity, unit, low_stock_threshold, last_updated, data)
    select v_rec.item_id, v_wh, 0, 0, 0, coalesce(mi.base_unit, mi.unit_type, 'piece'), 5, now(), '{}'::jsonb
    from public.menu_items mi where mi.id = v_rec.item_id::text
    on conflict (item_id, warehouse_id) do nothing;

    v_batch_created := v_batch_created + 1;
  end loop;

  raise notice 'Created % missing batches', v_batch_created;

  -- Step 3: Recalculate avg_cost in stock_management
  with affected as (
    select distinct b.item_id::text as item_id, b.warehouse_id
    from public.batches b
    where b.data->>'repairMigration' = '20260301020000'
  ),
  calc as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      case when sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)) > 0 then
        sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) * coalesce(b.unit_cost, 0))
        / sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0))
      else 0 end as avg_cost
    from public.batches b
    join affected a on a.item_id = b.item_id::text and a.warehouse_id = b.warehouse_id
    where coalesce(b.status, 'active') = 'active'
    group by b.item_id::text, b.warehouse_id
  )
  update public.stock_management sm
  set avg_cost = round(coalesce(c.avg_cost, sm.avg_cost), 6),
      updated_at = now(),
      last_updated = now()
  from calc c
  where sm.item_id::text = c.item_id and sm.warehouse_id = c.warehouse_id;

  -- Step 4: Update import_shipments_items.unit_price_fob for affected shipments
  -- Set bypass config to allow updating items for closed shipments
  perform set_config('app.internal_shipment_close', '1', false);

  -- Re-derive from the now-corrected purchase_receipt_items
  with corrected as (
    select
      pr.import_shipment_id as shipment_id,
      pri.item_id::text as item_id,
      case
        when sum(coalesce(pri.quantity, 0)) > 0 then
          sum(coalesce(pri.quantity, 0) * greatest(
            coalesce(pri.unit_cost, 0) - coalesce(pri.transport_cost, 0) - coalesce(pri.supply_tax_cost, 0), 0
          )) / sum(coalesce(pri.quantity, 0))
        else 0
      end as corrected_fob
    from public.purchase_receipt_items pri
    join public.purchase_receipts pr on pr.id = pri.receipt_id
    where pr.import_shipment_id is not null
    group by pr.import_shipment_id, pri.item_id
  )
  update public.import_shipments_items isi
  set unit_price_fob = round(greatest(coalesce(c.corrected_fob, 0), 0), 6),
      updated_at = now()
  from corrected c
  where isi.shipment_id = c.shipment_id
    and isi.item_id::text = c.item_id
    and abs(coalesce(isi.unit_price_fob, 0) - coalesce(c.corrected_fob, 0)) > 0.01;

  -- Clear bypass config
  perform set_config('app.internal_shipment_close', '', false);

end $$;

-- ===========================================================================
-- FIX 2: Update sync_import_shipment_items_from_receipts to use
--        item_unit_cost_to_base() for FOB calculation to prevent future 
--        data from being inflated.
-- ===========================================================================
create or replace function public.sync_import_shipment_items_from_receipts(
  p_shipment_id uuid,
  p_replace boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ship record;
  v_currency text;
  v_linked_count int := 0;
  v_upserted int := 0;
  v_deleted int := 0;
  v_base text;
begin
  if not public.has_admin_permission('procurement.manage') then
    raise exception 'not allowed';
  end if;

  if p_shipment_id is null then
    raise exception 'p_shipment_id is required';
  end if;

  v_base := public.get_base_currency();

  select *
  into v_ship
  from public.import_shipments s
  where s.id = p_shipment_id
  for update;

  if not found then
    raise exception 'shipment not found';
  end if;

  if v_ship.status = 'closed' then
    raise exception 'shipment is closed';
  end if;

  select count(*)
  into v_linked_count
  from public.purchase_receipts pr
  where pr.import_shipment_id = p_shipment_id;

  if v_linked_count = 0 then
    return jsonb_build_object('status','skipped','reason','no_linked_receipts','upserted',0,'deleted',0);
  end if;

  -- Use base currency always since we convert costs to base
  v_currency := coalesce(v_base, 'SAR');

  -- Aggregate items from linked receipts with CORRECT base-unit costs
  -- Use purchase_items + item_unit_cost_to_base() for accurate FOB
  with linked_receipts as (
    select pr.id as receipt_id, pr.purchase_order_id
    from public.purchase_receipts pr
    where pr.import_shipment_id = p_shipment_id
  ),
  receipt_qty as (
    select
      pri.item_id::text as item_id,
      sum(coalesce(pri.quantity, 0))::numeric as base_qty
    from linked_receipts lr
    join public.purchase_receipt_items pri on pri.receipt_id = lr.receipt_id
    group by pri.item_id
    having sum(coalesce(pri.quantity, 0)) > 0
  ),
  linked_orders as (
    select distinct lr.purchase_order_id
    from linked_receipts lr
    where lr.purchase_order_id is not null
  ),
  po_cost as (
    select
      pi.item_id::text as item_id,
      case
        when sum(coalesce(pi.qty_base, pi.quantity, 0)) > 0 then
          sum(
            coalesce(pi.qty_base, pi.quantity, 0)
            * public.item_unit_cost_to_base(pi.item_id::text, coalesce(pi.unit_cost, 0), pi.uom_id)
            * (case when upper(coalesce(po.currency, '')) <> upper(coalesce(v_base, '')) 
                    and coalesce(po.fx_rate, 0) > 0 
               then po.fx_rate else 1 end)
          )
          / sum(coalesce(pi.qty_base, pi.quantity, 0))
        else 0
      end::numeric as unit_cost_base_fob
    from public.purchase_items pi
    join linked_orders lo on lo.purchase_order_id = pi.purchase_order_id
    join public.purchase_orders po on po.id = pi.purchase_order_id
    group by pi.item_id
  ),
  agg as (
    select
      rq.item_id,
      rq.base_qty as quantity,
      coalesce(pc.unit_cost_base_fob, 0) as unit_price_fob
    from receipt_qty rq
    left join po_cost pc on pc.item_id = rq.item_id
  ),
  up as (
    insert into public.import_shipments_items(
      shipment_id,
      item_id,
      quantity,
      unit_price_fob,
      currency,
      expiry_date,
      notes,
      updated_at
    )
    select
      p_shipment_id,
      a.item_id,
      a.quantity,
      greatest(coalesce(a.unit_price_fob, 0), 0),
      v_currency,
      null,
      'synced_from_receipts',
      now()
    from agg a
    on conflict (shipment_id, item_id) do update
    set
      quantity = excluded.quantity,
      unit_price_fob = case when coalesce(import_shipments_items.unit_price_fob, 0) > 0 
                             and abs(import_shipments_items.unit_price_fob - excluded.unit_price_fob) < 0.01
                        then import_shipments_items.unit_price_fob 
                        else excluded.unit_price_fob end,
      currency = excluded.currency,
      updated_at = now()
    returning 1
  )
  select count(*) into v_upserted from up;

  if p_replace then
    with keep as (
      select pri.item_id::text as item_id
      from public.purchase_receipts pr
      join public.purchase_receipt_items pri on pri.receipt_id = pr.id
      where pr.import_shipment_id = p_shipment_id
      group by pri.item_id
      having sum(coalesce(pri.quantity, 0)) > 0
    ),
    del as (
      delete from public.import_shipments_items isi
      where isi.shipment_id = p_shipment_id
        and not exists (select 1 from keep k where k.item_id = isi.item_id::text)
      returning 1
    )
    select count(*) into v_deleted from del;
  end if;

  return jsonb_build_object(
    'status','ok',
    'linkedReceipts', v_linked_count,
    'upserted', v_upserted,
    'deleted', v_deleted,
    'currency', v_currency
  );
end;
$$;

revoke all on function public.sync_import_shipment_items_from_receipts(uuid, boolean) from public;
grant execute on function public.sync_import_shipment_items_from_receipts(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
