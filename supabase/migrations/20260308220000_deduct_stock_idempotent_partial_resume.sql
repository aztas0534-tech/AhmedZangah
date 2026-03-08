set app.allow_ledger_ddl = '1';

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
  v_already_sold_total numeric;
  v_existing_batch_qty numeric;
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

    select coalesce(sum(im.quantity), 0)
    into v_already_sold_total
    from public.inventory_movements im
    where im.reference_table = 'orders'
      and im.reference_id = p_order_id::text
      and im.movement_type = 'sale_out'
      and im.item_id::text = v_item_id::text
      and im.warehouse_id = v_item_warehouse_id;
    v_needed := greatest(coalesce(v_needed, 0) - coalesce(v_already_sold_total, 0), 0);

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
        if coalesce(v_is_food, false) and (v_batch.expiry_date is not null and v_batch.expiry_date < current_date) then
          raise exception 'NO_VALID_BATCH_AVAILABLE';
        end if;

        select coalesce(sum(im.quantity), 0)
        into v_existing_batch_qty
        from public.inventory_movements im
        where im.reference_table = 'orders'
          and im.reference_id = p_order_id::text
          and im.movement_type = 'sale_out'
          and im.item_id::text = v_item_id::text
          and im.warehouse_id = v_item_warehouse_id
          and im.batch_id = v_batch.batch_id;
        if coalesce(v_existing_batch_qty, 0) > 0 then
          continue;
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
            or (b.expiry_date is null or b.expiry_date >= current_date)
          )
        order by b.expiry_date asc nulls last, r.created_at asc, r.batch_id asc
        for update
      loop
        exit when v_needed <= 0;

        select coalesce(sum(im.quantity), 0)
        into v_existing_batch_qty
        from public.inventory_movements im
        where im.reference_table = 'orders'
          and im.reference_id = p_order_id::text
          and im.movement_type = 'sale_out'
          and im.item_id::text = v_item_id::text
          and im.warehouse_id = v_item_warehouse_id
          and im.batch_id = v_batch.batch_id;
        if coalesce(v_existing_batch_qty, 0) > 0 then
          continue;
        end if;

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
        if coalesce(v_is_food, false) and (v_batch.expiry_date is not null and v_batch.expiry_date < current_date) then
          raise exception 'NO_VALID_BATCH_AVAILABLE';
        end if;

        select coalesce(sum(im.quantity), 0)
        into v_existing_batch_qty
        from public.inventory_movements im
        where im.reference_table = 'orders'
          and im.reference_id = p_order_id::text
          and im.movement_type = 'sale_out'
          and im.item_id::text = v_item_id::text
          and im.warehouse_id = v_item_warehouse_id
          and im.batch_id = v_batch.batch_id;
        if coalesce(v_existing_batch_qty, 0) > 0 then
          continue;
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
            or (b.expiry_date is null or b.expiry_date >= current_date)
          )
        order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
        for update
      loop
        exit when v_needed <= 0;

        select coalesce(sum(im.quantity), 0)
        into v_existing_batch_qty
        from public.inventory_movements im
        where im.reference_table = 'orders'
          and im.reference_id = p_order_id::text
          and im.movement_type = 'sale_out'
          and im.item_id::text = v_item_id::text
          and im.warehouse_id = v_item_warehouse_id
          and im.batch_id = v_batch.batch_id;
        if coalesce(v_existing_batch_qty, 0) > 0 then
          continue;
        end if;

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
              or (b.expiry_date is null or b.expiry_date >= current_date)
            )
        ), 0),
        last_updated = now(),
        updated_at = now()
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = v_item_warehouse_id;
  end loop;
end;
$$;

create or replace function public.deduct_stock_on_delivery_v2(
  p_items jsonb,
  p_order_id uuid,
  p_warehouse_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.deduct_stock_on_delivery_v2(p_order_id, p_items, p_warehouse_id);
end;
$$;

notify pgrst, 'reload schema';
