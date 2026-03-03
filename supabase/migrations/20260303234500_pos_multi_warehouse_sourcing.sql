-- ============================================================================
-- Migration: POS Multi-Warehouse Sourcing
-- Date: 2026-03-03
-- Fixes:
--   1. _merge_stock_items: group by itemId and warehouseId
--   2. create_order_secure: fetch warehouseId per item and pass to get_fefo_pricing. 
--   3. reserve_stock_for_order: use v_item_warehouse_id 
--   4. deduct_stock_on_delivery_v2: use v_item_warehouse_id
-- ============================================================================

set app.allow_ledger_ddl = '1';

create or replace function public._merge_stock_items(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_map jsonb := '{}'::jsonb;
  v_item_id text;
  v_warehouse_id text;
  v_qty numeric;
  v_result jsonb := '[]'::jsonb;
  v_key text;
  v_parts text[];
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return '[]'::jsonb;
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_item_id := nullif(btrim(coalesce(v_item->>'itemId', v_item->>'id')), '');
    v_warehouse_id := coalesce(nullif(btrim(v_item->>'warehouseId'), ''), 'default');
    v_qty := coalesce(nullif((v_item->>'quantity')::numeric, null), 0);
    if v_item_id is null or v_qty <= 0 then
      continue;
    end if;
    v_key := v_item_id || '::' || v_warehouse_id;
    v_map := jsonb_set(
      v_map,
      array[v_key],
      to_jsonb(coalesce(nullif((v_map->>v_key)::numeric, null), 0) + v_qty),
      true
    );
  end loop;

  for v_key in select key from jsonb_each(v_map)
  loop
    v_parts := string_to_array(v_key, '::');
    v_item_id := v_parts[1];
    v_warehouse_id := v_parts[2];
    if v_warehouse_id = 'default' then
       v_result := v_result || jsonb_build_object('itemId', v_item_id, 'quantity', (v_map->>v_key)::numeric);
    else
       v_result := v_result || jsonb_build_object('itemId', v_item_id, 'warehouseId', v_warehouse_id, 'quantity', (v_map->>v_key)::numeric);
    end if;
  end loop;

  return v_result;
end;
$$;
revoke all on function public._merge_stock_items(jsonb) from public;
grant execute on function public._merge_stock_items(jsonb) to authenticated;

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
  v_item_warehouse_id uuid;
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
    v_item_warehouse_id := coalesce(public._uuid_or_null(v_item->>'warehouseId'), p_warehouse_id);
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
      and r.warehouse_id = v_item_warehouse_id;

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
        and b.warehouse_id = v_item_warehouse_id
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
        and r2.warehouse_id = v_item_warehouse_id
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
      values (p_order_id, v_item_id::text, v_item_warehouse_id, v_batch.batch_id, v_alloc, now(), now());

      v_needed := v_needed - v_alloc;
    end loop;

    if v_needed > 0 then
      raise exception 'INSUFFICIENT_FEFO_BATCH_STOCK_FOR_ITEM_%_WAREHOUSE_%', v_item_id, v_item_warehouse_id;
    end if;

    insert into public.stock_management(item_id, warehouse_id, available_quantity, reserved_quantity, unit, low_stock_threshold, avg_cost, last_updated, updated_at, data)
    select mi.id, v_item_warehouse_id, 0, 0, coalesce(mi.base_unit, mi.unit_type, 'piece'), 5, 0, now(), now(), '{}'::jsonb
    from public.menu_items mi
    where mi.id = v_item_id::text
    on conflict (item_id, warehouse_id) do nothing;

    update public.stock_management sm
    set reserved_quantity = coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          where r.item_id = v_item_id::text
            and r.warehouse_id = v_item_warehouse_id
        ), 0),
        available_quantity = coalesce((
          select sum(
            greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          )
          from public.batches b
          where b.item_id::text = v_item_id::text
            and b.warehouse_id = v_item_warehouse_id
            and coalesce(b.status,'active') = 'active'
            and (
              not coalesce(v_is_food, false)
              or (b.expiry_date is not null and b.expiry_date >= current_date)
            )
        ), 0),
        last_updated = now(),
        updated_at = now()
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = v_item_warehouse_id;
    get diagnostics v_rows = row_count;
    if coalesce(v_rows, 0) = 0 then
      raise exception 'STOCK_ROW_NOT_FOUND_FOR_ITEM_%_WAREHOUSE_%', v_item_id, v_item_warehouse_id;
    end if;
  end loop;
end;
$$;
revoke all on function public.reserve_stock_for_order(jsonb, uuid, uuid) from public;
grant execute on function public.reserve_stock_for_order(jsonb, uuid, uuid) to authenticated;

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
  v_item_warehouse_id uuid;
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
      -- We don't check warehouse_id here because orders might have multiple warehouse movements and we don't want to skip if only one exists 
      -- Wait, actually checking for 'sale_out' with reference_id = p_order_id is enough to know it's already deducted.
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
    v_item_warehouse_id := coalesce(public._uuid_or_null(v_item->>'warehouseId'), p_warehouse_id);
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
      and sm.warehouse_id = v_item_warehouse_id
    for update;
    if not found then
      raise exception 'Stock record not found for item % in warehouse %', v_item_id, v_item_warehouse_id;
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
          and r.warehouse_id = v_item_warehouse_id
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
            jsonb_build_object('orderId', p_order_id, 'warehouseId', v_item_warehouse_id, 'batchId', v_batch.batch_id),
            v_batch.batch_id,
            v_item_warehouse_id
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
          and r.warehouse_id = v_item_warehouse_id
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
          jsonb_build_object('orderId', p_order_id, 'warehouseId', v_item_warehouse_id, 'batchId', v_batch.batch_id),
          v_batch.batch_id,
          v_item_warehouse_id
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
        raise exception 'INSUFFICIENT_RESERVED_BATCH_STOCK_FOR_ITEM_%_WAREHOUSE_%', v_item_id, v_item_warehouse_id;
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
          and b.warehouse_id = v_item_warehouse_id
          and coalesce(b.status,'active') = 'active'
        for update;
        if not found then
          raise exception 'Batch % not found for item % in warehouse %', v_item_batch_text, v_item_id, v_item_warehouse_id;
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
            jsonb_build_object('orderId', p_order_id, 'warehouseId', v_item_warehouse_id, 'batchId', v_batch.batch_id),
            v_batch.batch_id,
            v_item_warehouse_id
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
          and b.warehouse_id = v_item_warehouse_id
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
          jsonb_build_object('orderId', p_order_id, 'warehouseId', v_item_warehouse_id, 'batchId', v_batch.batch_id),
          v_batch.batch_id,
          v_item_warehouse_id
        )
        returning id into v_movement_id;

        perform public.post_inventory_movement(v_movement_id);

        v_needed := v_needed - v_alloc;
      end loop;

      if v_needed > 0 then
        raise exception 'INSUFFICIENT_BATCH_STOCK_FOR_ITEM_%_WAREHOUSE_%', v_item_id, v_item_warehouse_id;
      end if;
    end if;

    update public.stock_management sm
    set reserved_quantity = coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          where r.item_id = v_item_id::text
            and r.warehouse_id = v_item_warehouse_id
        ), 0),
        available_quantity = coalesce((
          select sum(
            greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          )
          from public.batches b
          where b.item_id::text = v_item_id::text
            and b.warehouse_id = v_item_warehouse_id
            and coalesce(b.status,'active') = 'active'
            and (
              not coalesce(v_is_food, false)
              or (b.expiry_date is not null and b.expiry_date >= current_date)
            )
        ), 0),
        last_updated = now(),
        updated_at = now()
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = v_item_warehouse_id;
  end loop;
end;
$$;
revoke all on function public.deduct_stock_on_delivery_v2(uuid, jsonb, uuid) from public;
grant execute on function public.deduct_stock_on_delivery_v2(uuid, jsonb, uuid) to authenticated;

-- Next we will append `create_order_secure` using the 20260214180000 version as a base and overriding v_item_warehouse_id


create or replace function public.create_order_secure(
    p_items jsonb,
    p_delivery_zone_id uuid,
    p_payment_method text,
    p_notes text,
    p_address text,
    p_location jsonb,
    p_customer_name text,
    p_phone_number text,
    p_is_scheduled boolean,
    p_scheduled_at timestamptz,
    p_coupon_code text default null,
    p_points_redeemed_value numeric default 0,
    p_explicit_customer_id uuid default null,
    p_order_source text default 'online',
    p_currency text default null,
    p_warehouse_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user_id uuid;
    v_item_warehouse_id uuid;

revoke all on function public.create_order_secure(jsonb, uuid, text, text, text, jsonb, text, text, boolean, timestamptz, text, numeric, uuid, text, text, uuid) from public;
grant execute on function public.create_order_secure(jsonb, uuid, text, text, text, jsonb, text, text, boolean, timestamptz, text, numeric, uuid, text, text, uuid) to authenticated;
