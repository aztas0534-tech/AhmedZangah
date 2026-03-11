-- Patch manage_menu_item_stock to maintain batch balances and accept minimum_stock_level
-- Removes reliance on last_batch_id for adjustments

create or replace function public.manage_menu_item_stock(
  p_item_id uuid,
  p_quantity numeric,
  p_unit text,
  p_reason text,
  p_user_id uuid default auth.uid(),
  p_low_stock_threshold numeric default 5,
  p_is_wastage boolean default false,
  p_batch_id uuid default null,
  p_minimum_stock_level numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wh uuid;
  v_current record;
  v_old_qty numeric;
  v_old_avg numeric;
  v_diff numeric;
  v_batch record;
  v_reserved_other numeric;
  v_available numeric;
  v_needed numeric;
  v_alloc numeric;
  v_unit_cost numeric;
  v_total_cost numeric;
  v_movement_id uuid;
  v_history_id uuid;
  v_movement_type text;
  v_new_batch_id uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason is required';
  end if;
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_admin_permission('stock.manage') then
    raise exception 'not allowed';
  end if;

  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_quantity is null or p_quantity < 0 then
    raise exception 'invalid quantity';
  end if;

  v_wh := public._resolve_default_warehouse_id();
  if v_wh is null then
    raise exception 'warehouse_id is required';
  end if;

  insert into public.stock_management(item_id, warehouse_id, available_quantity, reserved_quantity, unit, low_stock_threshold, minimum_stock_level, avg_cost, last_updated, updated_at, data)
  select p_item_id::text, v_wh, 0, 0, coalesce(p_unit, 'piece'), coalesce(p_low_stock_threshold, 5), p_minimum_stock_level, 0, now(), now(), '{}'::jsonb
  on conflict (item_id, warehouse_id) do nothing;

  select coalesce(sm.available_quantity, 0), coalesce(sm.avg_cost, 0)
  into v_old_qty, v_old_avg
  from public.stock_management sm
  where sm.item_id::text = p_item_id::text
    and sm.warehouse_id = v_wh
  for update;

  v_diff := p_quantity - v_old_qty;

  if v_diff = 0 then
    update public.stock_management
    set unit = coalesce(p_unit, unit),
        low_stock_threshold = coalesce(p_low_stock_threshold, low_stock_threshold),
        minimum_stock_level = coalesce(p_minimum_stock_level, minimum_stock_level),
        updated_at = now(),
        last_updated = now()
    where item_id::text = p_item_id::text
      and warehouse_id = v_wh;
    return;
  end if;

  if v_diff > 0 then
    v_movement_type := 'adjust_in';
    v_new_batch_id := coalesce(p_batch_id, gen_random_uuid());

    insert into public.batch_balances(item_id, batch_id, warehouse_id, quantity, expiry_date)
    values (p_item_id::text, v_new_batch_id, v_wh, v_diff, null)
    on conflict (item_id, batch_id, warehouse_id)
    do update set
      quantity = public.batch_balances.quantity + excluded.quantity,
      updated_at = now();

    v_unit_cost := v_old_avg;
    v_total_cost := v_diff * v_unit_cost;

    insert into public.inventory_movements(
      item_id, movement_type, quantity, unit_cost, total_cost,
      reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
    )
    values (
      p_item_id::text, v_movement_type, v_diff, v_unit_cost, v_total_cost,
      'stock_history', null, now(), p_user_id,
      jsonb_build_object('reason', p_reason, 'warehouseId', v_wh, 'batchId', v_new_batch_id),
      v_new_batch_id, v_wh
    )
    returning id into v_movement_id;
    perform public.post_inventory_movement(v_movement_id);
  else
    v_movement_type := case when p_is_wastage then 'wastage_out' else 'adjust_out' end;
    v_needed := abs(v_diff);

    for v_batch in
      select bb.batch_id, bb.quantity, bb.expiry_date
      from public.batch_balances bb
      where bb.item_id = p_item_id::text
        and bb.warehouse_id = v_wh
        and bb.quantity > 0
        and (p_batch_id is null or bb.batch_id = p_batch_id)
      order by bb.expiry_date asc nulls last, bb.batch_id asc
    loop
      exit when v_needed <= 0;

      select coalesce(sum(br.quantity), 0)
      into v_reserved_other
      from public.batch_reservations br
      where br.item_id = p_item_id::text
        and br.warehouse_id = v_wh
        and br.batch_id = v_batch.batch_id;

      v_available := greatest(coalesce(v_batch.quantity, 0) - coalesce(v_reserved_other, 0), 0);
      if v_available <= 0 then
        continue;
      end if;

      v_alloc := least(v_needed, v_available);
      if v_alloc <= 0 then
        continue;
      end if;

      update public.batch_balances
      set quantity = quantity - v_alloc,
          updated_at = now()
      where item_id = p_item_id::text
        and batch_id = v_batch.batch_id
        and warehouse_id = v_wh;

      select im.unit_cost
      into v_unit_cost
      from public.inventory_movements im
      where im.batch_id = v_batch.batch_id
        and im.item_id::text = p_item_id::text
        and im.movement_type = 'purchase_in'
      order by im.occurred_at asc
      limit 1;
      v_unit_cost := coalesce(v_unit_cost, v_old_avg);
      v_total_cost := v_alloc * v_unit_cost;

      insert into public.inventory_movements(
        item_id, movement_type, quantity, unit_cost, total_cost,
        reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
      )
      values (
        p_item_id::text, v_movement_type, v_alloc, v_unit_cost, v_total_cost,
        'stock_history', null, now(), p_user_id,
        jsonb_build_object('reason', p_reason, 'warehouseId', v_wh, 'batchId', v_batch.batch_id, 'expiryDate', v_batch.expiry_date),
        v_batch.batch_id, v_wh
      )
      returning id into v_movement_id;

      perform public.post_inventory_movement(v_movement_id);

      v_needed := v_needed - v_alloc;
    end loop;

    if v_needed > 0 then
      raise exception 'insufficient unreserved stock for adjustment';
    end if;
  end if;

  v_history_id := gen_random_uuid();
  insert into public.stock_history(id, item_id, date, data)
  values (v_history_id, p_item_id::text, now()::date, jsonb_build_object('reason', p_reason, 'changedBy', p_user_id, 'fromQuantity', v_old_qty, 'toQuantity', p_quantity));

  update public.stock_management
  set available_quantity = coalesce((
        select sum(bb.quantity)
        from public.batch_balances bb
        where bb.item_id = p_item_id::text
          and bb.warehouse_id = v_wh
      ), 0),
      reserved_quantity = coalesce((
        select sum(br.quantity)
        from public.batch_reservations br
        where br.item_id = p_item_id::text
          and br.warehouse_id = v_wh
      ), 0),
      unit = coalesce(p_unit, unit),
      low_stock_threshold = coalesce(p_low_stock_threshold, low_stock_threshold),
      minimum_stock_level = coalesce(p_minimum_stock_level, minimum_stock_level),
      avg_cost = v_old_avg,
      last_updated = now(),
      updated_at = now()
  where item_id::text = p_item_id::text
    and warehouse_id = v_wh;

  update public.menu_items
  set data = jsonb_set(data, '{availableStock}', to_jsonb(p_quantity), true),
      updated_at = now()
  where id = p_item_id::text;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
  values (
    case when p_is_wastage then 'wastage_recorded' else 'stock_update' end,
    'stock',
    p_reason,
    p_user_id,
    now(),
    jsonb_build_object('itemId', p_item_id::text, 'warehouseId', v_wh, 'fromQuantity', v_old_qty, 'toQuantity', p_quantity, 'delta', v_diff)
  );
end;
$$;

revoke all on function public.manage_menu_item_stock(uuid, numeric, text, text, uuid, numeric, boolean, uuid, numeric) from public;
grant execute on function public.manage_menu_item_stock(uuid, numeric, text, text, uuid, numeric, boolean, uuid, numeric) to authenticated;
