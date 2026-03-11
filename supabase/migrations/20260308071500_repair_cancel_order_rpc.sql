-- ============================================================================
-- Repair: Ensure cancel_order(uuid, text) and its dependencies exist
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- 1. Ensure _resolve_default_warehouse_id helper
create or replace function public._resolve_default_warehouse_id()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_wh_id uuid;
begin
  select id into v_wh_id
  from public.warehouses
  where is_active = true
  order by created_at asc
  limit 1;
  return v_wh_id;
end;
$$;

-- 2. Ensure release_reserved_stock_for_order (3-arg overload)
create or replace function public.release_reserved_stock_for_order(
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
  v_wh uuid;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return;
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_item_id := coalesce(nullif(v_item->>'itemId',''), nullif(v_item->>'id',''));
    if v_item_id is null or v_item_id = '' then
      continue;
    end if;
    v_wh := coalesce(public._uuid_or_null(v_item->>'warehouseId'), p_warehouse_id);

    -- Delete reservations for this order+item+warehouse
    if p_order_id is not null then
      delete from public.order_item_reservations
      where order_id = p_order_id
        and item_id = v_item_id
        and (v_wh is null or warehouse_id = v_wh);

      -- Update stock_management reserved_quantity
      if v_wh is not null then
        update public.stock_management sm
        set reserved_quantity = coalesce((
              select sum(r.quantity)
              from public.order_item_reservations r
              where r.item_id = v_item_id
                and r.warehouse_id = v_wh
            ), 0),
            last_updated = now(),
            updated_at = now()
        where sm.item_id::text = v_item_id
          and sm.warehouse_id = v_wh;
      end if;
    end if;
  end loop;
end;
$$;

revoke all on function public.release_reserved_stock_for_order(jsonb, uuid, uuid) from public;
grant execute on function public.release_reserved_stock_for_order(jsonb, uuid, uuid) to authenticated;

-- 3. Ensure cancel_order(uuid, text) exists
create or replace function public.cancel_order(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_status text;
  v_order_data jsonb;
  v_items jsonb;
  v_warehouse_id uuid;
  v_new_status text;
  v_has_settlement boolean := false;
begin
  -- 1. Validate Order
  select status, data, data->'items'
  into v_order_status, v_order_data, v_items
  from public.orders
  where id = p_order_id;

  if not found then
    raise exception 'Order not found';
  end if;

  -- 2. Check Permissions
  if not public.is_admin() and not public.is_staff() then
    raise exception 'not allowed';
  end if;

  -- 3. Idempotency
  if v_order_status = 'cancelled' then
    return;
  end if;

  if v_order_status = 'delivered' then
    raise exception 'Cannot cancel a delivered order. Use Return process instead.';
  end if;

  -- 4. Check if order has been settled (invoiced, paid, etc.)
  v_has_settlement := (
    coalesce(nullif(v_order_data->>'paidAt',''), '') <> '' or
    coalesce(nullif(v_order_data->>'invoiceIssuedAt',''), '') <> '' or
    coalesce(nullif(v_order_data->>'deliveredAt',''), '') <> ''
  );

  if v_has_settlement then
    raise exception 'CANNOT_CANCEL_SETTLED';
  end if;

  -- 5. Release Reservations  
  v_warehouse_id := coalesce(
    public._uuid_or_null(v_order_data->>'warehouseId'),
    (select warehouse_id from public.orders where id = p_order_id),
    public._resolve_default_warehouse_id()
  );

  if v_items is not null and jsonb_array_length(v_items) > 0 then
    begin
      perform public.release_reserved_stock_for_order(
        p_items := v_items,
        p_order_id := p_order_id,
        p_warehouse_id := v_warehouse_id
      );
    exception when others then
      raise warning 'release_reserved_stock failed: %', sqlerrm;
    end;
  end if;

  -- 6. Update Order Status
  update public.orders
  set status = 'cancelled',
      cancelled_at = now(),
      data = jsonb_set(
        coalesce(data, '{}'::jsonb),
        '{cancellationReason}',
        to_jsonb(coalesce(p_reason, ''))
      )
  where id = p_order_id
  returning status into v_new_status;

  if v_new_status is null then
    raise exception 'Update failed: 0 rows affected. Check RLS or Triggers.';
  end if;

  if v_new_status <> 'cancelled' then
    raise exception 'Update failed: Status remained % after update. A trigger might be reverting changes.', v_new_status;
  end if;
end;
$$;

revoke all on function public.cancel_order(uuid, text) from public;
grant execute on function public.cancel_order(uuid, text) to authenticated;

-- 4. Force PostgREST reload
notify pgrst, 'reload schema';
notify pgrst, 'reload config';
