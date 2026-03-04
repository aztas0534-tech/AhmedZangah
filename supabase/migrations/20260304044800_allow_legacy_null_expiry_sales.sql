-- =============================================================================
-- السماح ببيع المواد الغذائية القديمة التي لا تملك تاريخ انتهاء (Legacy Stock)
-- =============================================================================

--------------------------------------------------------------------------------
-- 1. order_item_reserve
--------------------------------------------------------------------------------
create or replace function public.order_item_reserve(
  p_order_id uuid,
  p_item_id uuid,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_batch_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch record;
  v_needed numeric := p_quantity;
  v_alloc numeric;
  v_is_food boolean;
begin
  if auth.uid() is null then
    raise exception 'not allowed';
  end if;

  if p_quantity <= 0 then
    raise exception 'invalid quantity';
  end if;

  select public.is_food_category(m.category_id)
  into v_is_food
  from public.menu_items m
  where m.id = p_item_id;

  if p_batch_id is not null then
    select
      b.id as batch_id,
      b.expiry_date,
      greatest(
        coalesce(b.quantity_received,0)
        - coalesce(b.quantity_consumed,0)
        - coalesce(b.quantity_transferred,0)
        - coalesce((
            select sum(r.quantity)
            from public.order_item_reservations r
            where r.batch_id = b.id
          ), 0),
        0
      ) as available_qty
    into v_batch
    from public.batches b
    where b.id = p_batch_id
      and b.item_id = p_item_id
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status,'active') = 'active'
    for update;

    if not found then
      raise exception 'Batch % not found for item % in warehouse %', p_batch_id, p_item_id, p_warehouse_id;
    end if;

    -- السماح ببيع الدفعات التي لا تملك تاريخ انتهاء، ولكن منع المنتهية فعلياً
    if coalesce(v_is_food, false) and v_batch.expiry_date is not null and v_batch.expiry_date < current_date then
      raise exception 'NO_VALID_BATCH_AVAILABLE';
    end if;

    v_alloc := least(v_needed, coalesce(v_batch.available_qty, 0));
    if v_alloc > 0 then
      insert into public.order_item_reservations(order_id, item_id, batch_id, quantity, created_at, updated_at)
      values (p_order_id, p_item_id, v_batch.batch_id, v_alloc, now(), now())
      on conflict (order_id, item_id, batch_id) do update
      set quantity = public.order_item_reservations.quantity + excluded.quantity,
          updated_at = now();

      v_needed := v_needed - v_alloc;
    end if;
  end if;

  for v_batch in
    select
      b.id as batch_id,
      b.expiry_date,
      greatest(
        coalesce(b.quantity_received,0)
        - coalesce(b.quantity_consumed,0)
        - coalesce(b.quantity_transferred,0)
        - coalesce((
            select sum(r.quantity)
            from public.order_item_reservations r
            where r.batch_id = b.id
          ), 0),
        0
      ) as available_qty
    from public.batches b
    where b.item_id = p_item_id
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status,'active') = 'active'
      and greatest(
        coalesce(b.quantity_received,0)
        - coalesce(b.quantity_consumed,0)
        - coalesce(b.quantity_transferred,0)
        - coalesce((
            select sum(r.quantity)
            from public.order_item_reservations r
            where r.batch_id = b.id
          ), 0),
        0
      ) > 0
      and (p_batch_id is null or b.id <> p_batch_id)
      and (
        not coalesce(v_is_food, false)
        or b.expiry_date is null 
        or b.expiry_date >= current_date
      )
    order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
    for update
  loop
    exit when v_needed <= 0;

    v_alloc := least(v_needed, coalesce(v_batch.available_qty, 0));
    if v_alloc <= 0 then
      continue;
    end if;

    insert into public.order_item_reservations(order_id, item_id, batch_id, quantity, created_at, updated_at)
    values (p_order_id, p_item_id, v_batch.batch_id, v_alloc, now(), now())
    on conflict (order_id, item_id, batch_id) do update
    set quantity = public.order_item_reservations.quantity + excluded.quantity,
        updated_at = now();

    v_needed := v_needed - v_alloc;
  end loop;

  if v_needed > 0 then
    raise exception 'INSUFFICIENT_STOCK_FOR_ITEM_%_WAREHOUSE_%', p_item_id, p_warehouse_id;
  end if;
end;
$$;

revoke all on function public.order_item_reserve(uuid, uuid, uuid, numeric, uuid) from public;
grant execute on function public.order_item_reserve(uuid, uuid, uuid, numeric, uuid) to anon, authenticated;

--------------------------------------------------------------------------------
-- 2. order_allocate_item
--------------------------------------------------------------------------------
create or replace function public.order_allocate_item(
  p_order_id uuid,
  p_item record,
  p_primary_warehouse_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_id uuid;
  v_item_type text;
  v_manage_stock boolean;
  v_needed numeric;
  v_alloc numeric;
  v_unit_cost numeric;
  v_total_cost numeric;
  v_batch record;
  v_qr numeric;
  v_qc numeric;
  v_movement_id uuid;
  v_comp_item record;
  v_avg_cost numeric;
  v_item_batch_text text;
  v_item_warehouse_id uuid;
  v_is_food boolean;
begin
  if auth.uid() is null then
    raise exception 'not allowed';
  end if;

  v_item_id := nullif(p_item.item_id, '')::uuid;
  v_needed := coalesce(p_item.quantity, 0);

  if v_item_id is null or v_needed <= 0 then
    return;
  end if;

  select type, coalesce(manage_stock, true), public.is_food_category(category_id)
  into v_item_type, v_manage_stock, v_is_food
  from public.menu_items
  where id = v_item_id;

  if v_item_type is null then
    return;
  end if;

  if v_item_type = 'raw_material' then
    return;
  end if;

  v_avg_cost := public.calculate_average_cost(v_item_id);

  if not v_manage_stock then
    if v_avg_cost is not null and v_avg_cost > 0 then
      v_total_cost := v_needed * v_avg_cost;
      insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
      values (p_order_id, v_item_id::text, v_needed, v_avg_cost, v_total_cost, now());
    end if;
    return;
  end if;

  if v_item_type = 'composite' then
    for v_comp_item in
      select component_id, quantity
      from public.menu_item_components
      where item_id = v_item_id
    loop
      perform public.order_allocate_item(
        p_order_id,
        jsonb_build_object('item_id', v_comp_item.component_id, 'quantity', v_needed * v_comp_item.quantity)::record,
        p_primary_warehouse_id
      );
    end loop;
    return;
  end if;

  if v_item_type = 'standard' then
    v_item_batch_text := null;
    begin
        v_item_batch_text := nullif(translate(trim((p_item.data->>'batchId')::text), '"', ''), '');
    exception when others then
        v_item_batch_text := null;
    end;

    v_item_warehouse_id := p_primary_warehouse_id;
    begin
        v_item_warehouse_id := nullif(translate(trim((p_item.data->>'warehouseId')::text), '"', ''), '')::uuid;
    exception when others then
        v_item_warehouse_id := p_primary_warehouse_id;
    end;
    if v_item_warehouse_id is null then
       v_item_warehouse_id := p_primary_warehouse_id;
    end if;

    if exists (
      select 1 from public.order_item_reservations
      where order_id = p_order_id and item_id = v_item_id
    ) then
      for v_batch in
        select
          r.id as reservation_id,
          r.batch_id,
          r.quantity as reserved_qty,
          b.expiry_date,
          b.unit_cost
        from public.order_item_reservations r
        join public.batches b on b.id = r.batch_id
        where r.order_id = p_order_id
          and r.item_id = v_item_id
          and r.quantity > 0
        order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
        for update
      loop
        exit when v_needed <= 0;
        v_alloc := least(v_needed, v_batch.reserved_qty);
        if v_alloc <= 0 then
          continue;
        end if;

        if coalesce(v_is_food, false) and v_batch.expiry_date is not null and v_batch.expiry_date < current_date then
           raise exception 'NO_VALID_BATCH_AVAILABLE';
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
          jsonb_build_object('orderId', p_order_id, 'reservationId', v_batch.reservation_id, 'warehouseId', v_item_warehouse_id, 'batchId', v_batch.batch_id),
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
        if coalesce(v_is_food, false) and v_batch.expiry_date is not null and v_batch.expiry_date < current_date then
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
            or b.expiry_date is null 
            or b.expiry_date >= current_date
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
  end if;
end;
$$;

revoke all on function public.order_allocate_item(uuid, record, uuid) from public;
grant execute on function public.order_allocate_item(uuid, record, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
