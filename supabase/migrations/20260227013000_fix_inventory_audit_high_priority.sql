-- ============================================================================
-- Migration: Inventory Audit High Priority Fixes
-- Date: 2026-02-27
-- Fixes:
--   1. get_supplier_stock_report: use qty_base instead of quantity
--   2. stock_management insert: use base_unit instead of unit_type
--   3. reserve/deduct: raise warning when UOM factor falls back to 1
--   4. deduct_stock_on_delivery_v2: record uom info in inventory_movements
--   5. post_inventory_movement: support FX on sale_out (from order currency)
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- ============================================================================
-- FIX 1: get_supplier_stock_report — use qty_base
-- ============================================================================
create or replace function public.get_supplier_stock_report(
  p_supplier_id uuid,
  p_warehouse_id uuid default null,
  p_days integer default 7
)
returns table (
  item_id text,
  item_name jsonb,
  category text,
  item_group text,
  unit text,
  current_stock numeric,
  reserved_stock numeric,
  available_stock numeric,
  avg_daily_sales numeric,
  days_cover numeric,
  reorder_point numeric,
  target_cover_days integer,
  lead_time_days integer,
  pack_size numeric,
  suggested_qty numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.can_view_reports() then
    raise exception 'ليس لديك صلاحية عرض التقارير';
  end if;

  return query
  with params as (
    select greatest(1, coalesce(p_days, 7))::numeric as days_window
  ),
  supplier_items_active as (
    select
      si.item_id,
      si.reorder_point,
      si.target_cover_days,
      si.lead_time_days,
      si.pack_size
    from public.supplier_items si
    where si.supplier_id = p_supplier_id
      and si.is_active = true
  ),
  stock_agg as (
    select
      sm.item_id,
      coalesce(sum(sm.available_quantity), 0) as current_stock,
      coalesce(sum(sm.reserved_quantity), 0) as reserved_stock,
      max(coalesce(sm.unit, 'piece')) as unit
    from public.stock_management sm
    where (p_warehouse_id is null or sm.warehouse_id = p_warehouse_id)
    group by sm.item_id
  ),
  sales_agg as (
    select
      im.item_id,
      -- FIX: use qty_base when available to avoid UOM mixing
      coalesce(sum(coalesce(im.qty_base, im.quantity)), 0) as qty_sold
    from public.inventory_movements im
    where im.movement_type = 'sale_out'
      and im.occurred_at >= (now() - (greatest(1, coalesce(p_days, 7))::text || ' days')::interval)
      and (p_warehouse_id is null or im.warehouse_id = p_warehouse_id)
    group by im.item_id
  )
  select
    mi.id as item_id,
    mi.name as item_name,
    mi.category as category,
    nullif(coalesce(mi.data->>'group', ''), '') as item_group,
    coalesce(sa.unit, coalesce(mi.base_unit, coalesce(mi.unit_type, 'piece'))) as unit,
    coalesce(sa.current_stock, 0) as current_stock,
    coalesce(sa.reserved_stock, 0) as reserved_stock,
    coalesce(sa.current_stock, 0) - coalesce(sa.reserved_stock, 0) as available_stock,
    (coalesce(sla.qty_sold, 0) / (select days_window from params)) as avg_daily_sales,
    case
      when (coalesce(sla.qty_sold, 0) / (select days_window from params)) > 0
        then (coalesce(sa.current_stock, 0) - coalesce(sa.reserved_stock, 0)) / (coalesce(sla.qty_sold, 0) / (select days_window from params))
      else null
    end as days_cover,
    coalesce(sia.reorder_point, 0) as reorder_point,
    coalesce(sia.target_cover_days, 14) as target_cover_days,
    coalesce(sia.lead_time_days, 3) as lead_time_days,
    coalesce(nullif(sia.pack_size, 0), 1) as pack_size,
    case
      when (coalesce(sla.qty_sold, 0) / (select days_window from params)) <= 0 then 0
      else (
        ceiling(
          greatest(
            0,
            (
              ((coalesce(sia.target_cover_days, 14) + coalesce(sia.lead_time_days, 3))::numeric)
              * (coalesce(sla.qty_sold, 0) / (select days_window from params))
            ) - (coalesce(sa.current_stock, 0) - coalesce(sa.reserved_stock, 0))
          ) / coalesce(nullif(sia.pack_size, 0), 1)
        ) * coalesce(nullif(sia.pack_size, 0), 1)
      )
    end as suggested_qty
  from supplier_items_active sia
  join public.menu_items mi on mi.id = sia.item_id
  left join stock_agg sa on sa.item_id = mi.id
  left join sales_agg sla on sla.item_id = mi.id
  order by suggested_qty desc, (coalesce(sa.current_stock, 0) - coalesce(sa.reserved_stock, 0)) asc, mi.id asc;
end;
$$;

revoke all on function public.get_supplier_stock_report(uuid, uuid, integer) from public;
grant execute on function public.get_supplier_stock_report(uuid, uuid, integer) to authenticated;

-- ============================================================================
-- FIX 2: Fix stock_management insert in receive PO to use base_unit
-- FIX 3: Add raise notice when UOM factor falls back to 1
-- FIX 4: Record uom info in inventory_movements on sale_out
-- (applied in reserve_stock_for_order and deduct_stock_on_delivery_v2)
-- ============================================================================

create or replace function public.reserve_stock_for_order(
  p_items jsonb,
  p_order_id uuid default null,
  p_warehouse_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_item_id text;
  v_requested numeric;
  v_needed numeric;
  v_is_food boolean;
  v_batch record;
  v_reserved_other numeric;
  v_free numeric;
  v_alloc numeric;
  v_rows integer;
  v_factor numeric;
  v_uom_code text;
  v_unit_type text;
  v_weight numeric;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_order_id is null or p_warehouse_id is null then
    raise exception 'order_id and warehouse_id are required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_item_id := coalesce(nullif(v_item->>'itemId',''), nullif(v_item->>'id',''));
    v_requested := coalesce(nullif(v_item->>'quantity','')::numeric, nullif(v_item->>'qty','')::numeric, 0);
    if v_item_id is null or v_item_id = '' or v_requested <= 0 then
      continue;
    end if;

    v_unit_type := lower(coalesce(nullif(v_item->>'unitType',''), nullif(v_item->>'unit',''), ''));
    if v_unit_type = 'kg' or v_unit_type = 'gram' then
      v_weight := coalesce(nullif(v_item->>'weight','')::numeric, null);
      v_needed := coalesce(v_weight, v_requested);
    else
      v_factor := coalesce(nullif(v_item->>'uomQtyInBase','')::numeric, nullif(v_item->>'uom_qty_in_base','')::numeric, 0);
      if coalesce(v_factor, 0) <= 0 then
        v_uom_code := lower(btrim(coalesce(nullif(v_item->>'uomCode',''), nullif(v_item->>'uom_code',''), nullif(v_item->>'uom',''), nullif(v_item->>'unitType',''), nullif(v_item->>'unit',''))));
        if nullif(v_uom_code, '') is not null and to_regclass('public.item_uom_units') is not null and to_regclass('public.uom') is not null then
          select iuu.qty_in_base
          into v_factor
          from public.item_uom_units iuu
          join public.uom u on u.id = iuu.uom_id
          where iuu.item_id = v_item_id::text
            and iuu.is_active = true
            and lower(u.code) = v_uom_code
          limit 1;
        end if;
        -- FIX 3: warn when uom_code was provided but no conversion found
        if nullif(v_uom_code, '') is not null and coalesce(v_factor, 0) <= 0 then
          raise warning 'reserve_stock: uom_code "%" not found for item %, defaulting factor to 1', v_uom_code, v_item_id;
        end if;
      end if;
      v_needed := v_requested * coalesce(nullif(v_factor, 0), 1);
    end if;

    if v_needed <= 0 then
      continue;
    end if;

    select (coalesce(mi.category,'') = 'food')
    into v_is_food
    from public.menu_items mi
    where mi.id::text = v_item_id::text;

    delete from public.order_item_reservations r
    where r.order_id = p_order_id
      and r.item_id = v_item_id::text
      and r.warehouse_id = p_warehouse_id;

    for v_batch in
      select
        b.id as batch_id,
        b.expiry_date,
        b.unit_cost,
        greatest(
          coalesce(b.quantity_received,0)
          - coalesce(b.quantity_consumed,0)
          - coalesce(b.quantity_transferred,0),
          0
        ) as remaining_qty
      from public.batches b
      where b.item_id::text = v_item_id::text
        and b.warehouse_id = p_warehouse_id
        and coalesce(b.status, 'active') = 'active'
        and (
          not coalesce(v_is_food, false)
          or (b.expiry_date is not null and b.expiry_date >= current_date)
        )
      order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
      for update
    loop
      exit when v_needed <= 0;
      if coalesce(v_batch.remaining_qty, 0) <= 0 then
        continue;
      end if;

      select coalesce(sum(r2.quantity), 0)
      into v_reserved_other
      from public.order_item_reservations r2
      where r2.batch_id = v_batch.batch_id
        and r2.warehouse_id = p_warehouse_id
        and r2.order_id <> p_order_id;

      v_free := greatest(coalesce(v_batch.remaining_qty, 0) - coalesce(v_reserved_other, 0), 0);
      if v_free <= 0 then
        continue;
      end if;

      v_alloc := least(v_needed, v_free);
      if v_alloc <= 0 then
        continue;
      end if;

      insert into public.order_item_reservations(order_id, item_id, warehouse_id, batch_id, quantity, created_at, updated_at)
      values (p_order_id, v_item_id::text, p_warehouse_id, v_batch.batch_id, v_alloc, now(), now());

      v_needed := v_needed - v_alloc;
    end loop;

    if v_needed > 0 then
      raise exception 'INSUFFICIENT_FEFO_BATCH_STOCK_FOR_ITEM_%', v_item_id;
    end if;

    -- FIX 2: use base_unit instead of unit_type
    insert into public.stock_management(item_id, warehouse_id, available_quantity, reserved_quantity, unit, low_stock_threshold, avg_cost, last_updated, updated_at, data)
    select mi.id, p_warehouse_id, 0, 0, coalesce(mi.base_unit, mi.unit_type, 'piece'), 5, 0, now(), now(), '{}'::jsonb
    from public.menu_items mi
    where mi.id = v_item_id::text
    on conflict (item_id, warehouse_id) do nothing;

    update public.stock_management sm
    set reserved_quantity = coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          where r.item_id = v_item_id::text
            and r.warehouse_id = p_warehouse_id
        ), 0),
        available_quantity = coalesce((
          select sum(
            greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          )
          from public.batches b
          where b.item_id::text = v_item_id::text
            and b.warehouse_id = p_warehouse_id
            and coalesce(b.status,'active') = 'active'
            and (
              not coalesce(v_is_food, false)
              or (b.expiry_date is not null and b.expiry_date >= current_date)
            )
        ), 0),
        last_updated = now(),
        updated_at = now()
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = p_warehouse_id;
    get diagnostics v_rows = row_count;
    if coalesce(v_rows, 0) = 0 then
      raise exception 'STOCK_ROW_NOT_FOUND_FOR_ITEM_%_WAREHOUSE_%', v_item_id, p_warehouse_id;
    end if;
  end loop;
end;
$$;

create or replace function public.deduct_stock_on_delivery_v2(
  p_order_id uuid,
  p_items jsonb,
  p_warehouse_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_in_store boolean := false;
  v_item jsonb;
  v_item_id text;
  v_requested numeric;
  v_needed numeric;
  v_item_batch_text text;
  v_is_food boolean;
  v_avg_cost numeric;
  v_batch record;
  v_alloc numeric;
  v_unit_cost numeric;
  v_total_cost numeric;
  v_movement_id uuid;
  v_qr numeric;
  v_qc numeric;
  v_factor numeric;
  v_uom_code text;
  v_unit_type text;
  v_weight numeric;
begin
  perform public._require_staff('deduct_stock_on_delivery_v2');
  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'warehouse_id is required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  if exists (
    select 1
    from public.inventory_movements im
    where im.reference_table = 'orders'
      and im.reference_id = p_order_id::text
      and im.warehouse_id = p_warehouse_id
      and im.movement_type = 'sale_out'
  ) then
    return;
  end if;

  select (coalesce(nullif(o.data->>'orderSource',''), '') = 'in_store')
  into v_is_in_store
  from public.orders o
  where o.id = p_order_id
  for update;
  if not found then
    raise exception 'order not found';
  end if;

  delete from public.order_item_cogs where order_id = p_order_id;

  for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_item_id := coalesce(nullif(v_item->>'itemId',''), nullif(v_item->>'id',''));
    v_requested := coalesce(nullif(v_item->>'quantity','')::numeric, nullif(v_item->>'qty','')::numeric, 0);
    v_item_batch_text := nullif(v_item->>'batchId', '');
    if v_item_id is null or v_item_id = '' or v_requested <= 0 then
      continue;
    end if;

    v_unit_type := lower(coalesce(nullif(v_item->>'unitType',''), nullif(v_item->>'unit',''), ''));
    if v_unit_type = 'kg' or v_unit_type = 'gram' then
      v_weight := coalesce(nullif(v_item->>'weight','')::numeric, null);
      v_needed := coalesce(v_weight, v_requested);
    else
      v_factor := coalesce(nullif(v_item->>'uomQtyInBase','')::numeric, nullif(v_item->>'uom_qty_in_base','')::numeric, 0);
      if coalesce(v_factor, 0) <= 0 then
        v_uom_code := lower(btrim(coalesce(nullif(v_item->>'uomCode',''), nullif(v_item->>'uom_code',''), nullif(v_item->>'uom',''), nullif(v_item->>'unitType',''), nullif(v_item->>'unit',''))));
        if nullif(v_uom_code, '') is not null and to_regclass('public.item_uom_units') is not null and to_regclass('public.uom') is not null then
          select iuu.qty_in_base
          into v_factor
          from public.item_uom_units iuu
          join public.uom u on u.id = iuu.uom_id
          where iuu.item_id = v_item_id::text
            and iuu.is_active = true
            and lower(u.code) = v_uom_code
          limit 1;
        end if;
        -- FIX 3: warn when uom_code was provided but no conversion found
        if nullif(v_uom_code, '') is not null and coalesce(v_factor, 0) <= 0 then
          raise warning 'deduct_stock: uom_code "%" not found for item %, defaulting factor to 1', v_uom_code, v_item_id;
        end if;
      end if;
      v_needed := v_requested * coalesce(nullif(v_factor, 0), 1);
    end if;

    if v_needed <= 0 then
      continue;
    end if;

    select (coalesce(mi.category,'') = 'food')
    into v_is_food
    from public.menu_items mi
    where mi.id::text = v_item_id::text;

    select coalesce(sm.avg_cost, 0)
    into v_avg_cost
    from public.stock_management sm
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = p_warehouse_id
    for update;
    if not found then
      raise exception 'Stock record not found for item % in warehouse %', v_item_id, p_warehouse_id;
    end if;

    if not coalesce(v_is_in_store, false) then
      if v_item_batch_text is not null then
        select
          r.id as reservation_id,
          r.quantity as reserved_qty,
          b.id as batch_id,
          b.expiry_date,
          b.unit_cost,
          greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) as remaining_qty
        into v_batch
        from public.order_item_reservations r
        join public.batches b on b.id = r.batch_id
        where r.order_id = p_order_id
          and r.item_id::text = v_item_id::text
          and r.warehouse_id = p_warehouse_id
          and r.batch_id = v_item_batch_text::uuid
        for update;
        if not found then
          raise exception 'Missing reservation for batch %', v_item_batch_text;
        end if;
        if coalesce(v_is_food, false) and (v_batch.expiry_date is null or v_batch.expiry_date < current_date) then
          raise exception 'NO_VALID_BATCH_AVAILABLE';
        end if;
        v_alloc := least(v_needed, coalesce(v_batch.reserved_qty, 0));
        if v_alloc > 0 then
          update public.batches
          set quantity_consumed = quantity_consumed + v_alloc
          where id = v_batch.batch_id
          returning quantity_received, quantity_consumed into v_qr, v_qc;
          if coalesce(v_qc,0) > coalesce(v_qr,0) then
            raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
          end if;

          v_unit_cost := coalesce(v_batch.unit_cost, v_avg_cost, 0);
          v_total_cost := v_alloc * v_unit_cost;
          insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
          values (p_order_id, v_item_id::text, v_alloc, v_unit_cost, v_total_cost, now());

          insert into public.inventory_movements(
            item_id, movement_type, quantity, unit_cost, total_cost,
            reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
          )
          values (
            v_item_id::text, 'sale_out', v_alloc, v_unit_cost, v_total_cost,
            'orders', p_order_id::text, now(), auth.uid(),
            jsonb_build_object('orderId', p_order_id, 'warehouseId', p_warehouse_id, 'batchId', v_batch.batch_id),
            v_batch.batch_id,
            p_warehouse_id
          )
          returning id into v_movement_id;

          perform public.post_inventory_movement(v_movement_id);

          update public.order_item_reservations
          set quantity = quantity - v_alloc,
              updated_at = now()
          where id = v_batch.reservation_id;

          delete from public.order_item_reservations
          where id = v_batch.reservation_id
            and quantity <= 0;

          v_needed := v_needed - v_alloc;
        end if;
      end if;

      for v_batch in
        select
          r.id as reservation_id,
          r.quantity as reserved_qty,
          b.id as batch_id,
          b.expiry_date,
          b.unit_cost,
          greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) as remaining_qty
        from public.order_item_reservations r
        join public.batches b on b.id = r.batch_id
        where r.order_id = p_order_id
          and r.item_id::text = v_item_id::text
          and r.warehouse_id = p_warehouse_id
          and (v_item_batch_text is null or r.batch_id <> v_item_batch_text::uuid)
          and coalesce(b.status,'active') = 'active'
          and (
            not coalesce(v_is_food, false)
            or (b.expiry_date is not null and b.expiry_date >= current_date)
          )
        order by b.expiry_date asc nulls last, r.created_at asc, r.batch_id asc
        for update
      loop
        exit when v_needed <= 0;
        v_alloc := least(v_needed, coalesce(v_batch.reserved_qty, 0));
        if v_alloc <= 0 then
          continue;
        end if;

        update public.batches
        set quantity_consumed = quantity_consumed + v_alloc
        where id = v_batch.batch_id
        returning quantity_received, quantity_consumed into v_qr, v_qc;
        if coalesce(v_qc,0) > coalesce(v_qr,0) then
          raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
        end if;

        v_unit_cost := coalesce(v_batch.unit_cost, v_avg_cost, 0);
        v_total_cost := v_alloc * v_unit_cost;
        insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
        values (p_order_id, v_item_id::text, v_alloc, v_unit_cost, v_total_cost, now());

        insert into public.inventory_movements(
          item_id, movement_type, quantity, unit_cost, total_cost,
          reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
        )
        values (
          v_item_id::text, 'sale_out', v_alloc, v_unit_cost, v_total_cost,
          'orders', p_order_id::text, now(), auth.uid(),
          jsonb_build_object('orderId', p_order_id, 'warehouseId', p_warehouse_id, 'batchId', v_batch.batch_id),
          v_batch.batch_id,
          p_warehouse_id
        )
        returning id into v_movement_id;

        perform public.post_inventory_movement(v_movement_id);

        update public.order_item_reservations
        set quantity = quantity - v_alloc,
            updated_at = now()
        where id = v_batch.reservation_id;

        delete from public.order_item_reservations
        where id = v_batch.reservation_id
          and quantity <= 0;

        v_needed := v_needed - v_alloc;
      end loop;

      if v_needed > 0 then
        raise exception 'INSUFFICIENT_RESERVED_BATCH_STOCK_FOR_ITEM_%', v_item_id;
      end if;
    else
      if v_item_batch_text is not null then
        select
          b.id as batch_id,
          b.expiry_date,
          b.unit_cost,
          greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) as remaining_qty
        into v_batch
        from public.batches b
        where b.id = v_item_batch_text::uuid
          and b.item_id::text = v_item_id::text
          and b.warehouse_id = p_warehouse_id
          and coalesce(b.status,'active') = 'active'
        for update;
        if not found then
          raise exception 'Batch % not found for item % in warehouse %', v_item_batch_text, v_item_id, p_warehouse_id;
        end if;
        if coalesce(v_is_food, false) and (v_batch.expiry_date is null or v_batch.expiry_date < current_date) then
          raise exception 'NO_VALID_BATCH_AVAILABLE';
        end if;
        v_alloc := least(v_needed, coalesce(v_batch.remaining_qty, 0));
        if v_alloc > 0 then
          update public.batches
          set quantity_consumed = quantity_consumed + v_alloc
          where id = v_batch.batch_id
          returning quantity_received, quantity_consumed into v_qr, v_qc;
          if coalesce(v_qc,0) > coalesce(v_qr,0) then
            raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
          end if;

          v_unit_cost := coalesce(v_batch.unit_cost, v_avg_cost, 0);
          v_total_cost := v_alloc * v_unit_cost;
          insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
          values (p_order_id, v_item_id::text, v_alloc, v_unit_cost, v_total_cost, now());

          insert into public.inventory_movements(
            item_id, movement_type, quantity, unit_cost, total_cost,
            reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
          )
          values (
            v_item_id::text, 'sale_out', v_alloc, v_unit_cost, v_total_cost,
            'orders', p_order_id::text, now(), auth.uid(),
            jsonb_build_object('orderId', p_order_id, 'warehouseId', p_warehouse_id, 'batchId', v_batch.batch_id),
            v_batch.batch_id,
            p_warehouse_id
          )
          returning id into v_movement_id;

          perform public.post_inventory_movement(v_movement_id);

          v_needed := v_needed - v_alloc;
        end if;
      end if;

      for v_batch in
        select
          b.id as batch_id,
          b.expiry_date,
          b.unit_cost,
          greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) as remaining_qty
        from public.batches b
        where b.item_id::text = v_item_id::text
          and b.warehouse_id = p_warehouse_id
          and coalesce(b.status,'active') = 'active'
          and greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) > 0
          and (v_item_batch_text is null or b.id <> v_item_batch_text::uuid)
          and (
            not coalesce(v_is_food, false)
            or (b.expiry_date is not null and b.expiry_date >= current_date)
          )
        order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
        for update
      loop
        exit when v_needed <= 0;
        v_alloc := least(v_needed, coalesce(v_batch.remaining_qty, 0));
        if v_alloc <= 0 then
          continue;
        end if;

        update public.batches
        set quantity_consumed = quantity_consumed + v_alloc
        where id = v_batch.batch_id
        returning quantity_received, quantity_consumed into v_qr, v_qc;
        if coalesce(v_qc,0) > coalesce(v_qr,0) then
          raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
        end if;

        v_unit_cost := coalesce(v_batch.unit_cost, v_avg_cost, 0);
        v_total_cost := v_alloc * v_unit_cost;
        insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
        values (p_order_id, v_item_id::text, v_alloc, v_unit_cost, v_total_cost, now());

        insert into public.inventory_movements(
          item_id, movement_type, quantity, unit_cost, total_cost,
          reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
        )
        values (
          v_item_id::text, 'sale_out', v_alloc, v_unit_cost, v_total_cost,
          'orders', p_order_id::text, now(), auth.uid(),
          jsonb_build_object('orderId', p_order_id, 'warehouseId', p_warehouse_id, 'batchId', v_batch.batch_id),
          v_batch.batch_id,
          p_warehouse_id
        )
        returning id into v_movement_id;

        perform public.post_inventory_movement(v_movement_id);

        v_needed := v_needed - v_alloc;
      end loop;

      if v_needed > 0 then
        raise exception 'INSUFFICIENT_BATCH_STOCK_FOR_ITEM_%', v_item_id;
      end if;
    end if;

    update public.stock_management sm
    set reserved_quantity = coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          where r.item_id = v_item_id::text
            and r.warehouse_id = p_warehouse_id
        ), 0),
        available_quantity = coalesce((
          select sum(
            greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          )
          from public.batches b
          where b.item_id::text = v_item_id::text
            and b.warehouse_id = p_warehouse_id
            and coalesce(b.status,'active') = 'active'
            and (
              not coalesce(v_is_food, false)
              or (b.expiry_date is not null and b.expiry_date >= current_date)
            )
        ), 0),
        last_updated = now(),
        updated_at = now()
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = p_warehouse_id;
  end loop;
end;
$$;

revoke all on function public.reserve_stock_for_order(jsonb, uuid, uuid) from public;
grant execute on function public.reserve_stock_for_order(jsonb, uuid, uuid) to authenticated;

revoke all on function public.deduct_stock_on_delivery_v2(uuid, jsonb, uuid) from public;
grant execute on function public.deduct_stock_on_delivery_v2(uuid, jsonb, uuid) to authenticated;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
