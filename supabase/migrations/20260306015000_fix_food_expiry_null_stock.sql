-- Fix: recompute_stock_for_item incorrectly excludes food-category batches
-- with NULL expiry_date. The condition was:
--   (b.expiry_date is not null and b.expiry_date >= current_date)
-- This means food batches WITHOUT an expiry date are excluded (treated as expired).
-- Fix: treat NULL expiry_date as "no expiry" (i.e., always valid).

-- Get the full function and recreate it with the fix
create or replace function public.recompute_stock_for_item(p_item_id text, p_warehouse_id uuid)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_is_food boolean := false;
begin
  perform public._require_staff('recompute_stock_for_item');

  if p_item_id is null or btrim(p_item_id) = '' then
    raise exception 'item_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'warehouse_id is required';
  end if;

  select (coalesce(mi.category,'') = 'food')
  into v_is_food
  from public.menu_items mi
  where mi.id::text = p_item_id::text;

  insert into public.stock_management(item_id, warehouse_id, available_quantity, qc_hold_quantity, reserved_quantity, unit, low_stock_threshold, last_updated, data)
  select p_item_id, p_warehouse_id, 0, 0, 0, coalesce(mi.unit_type, 'piece'), 5, now(), '{}'::jsonb
  from public.menu_items mi
  where mi.id::text = p_item_id::text
  on conflict (item_id, warehouse_id) do nothing;

  update public.stock_management sm
  set
    reserved_quantity = coalesce((
      select sum(r.quantity)
      from public.order_item_reservations r
      where r.item_id::text = p_item_id::text
        and r.warehouse_id = p_warehouse_id
    ), 0),
    available_quantity = coalesce((
      select sum(
        greatest(
          coalesce(b.quantity_received,0)
          - coalesce(b.quantity_consumed,0)
          - coalesce(b.quantity_transferred,0),
          0
        )
      )
      from public.batches b
      where b.item_id::text = p_item_id::text
        and b.warehouse_id = p_warehouse_id
        and coalesce(b.status,'active') = 'active'
        and coalesce(b.qc_status,'') = 'released'
        and not exists (
          select 1 from public.batch_recalls br
          where br.batch_id = b.id and br.status = 'active'
        )
        and (
          not coalesce(v_is_food, false)
          or b.expiry_date is null           -- FIX: NULL expiry = no expiry = always valid
          or b.expiry_date >= current_date   -- has expiry and not expired
        )
    ), 0),
    qc_hold_quantity = coalesce((
      select sum(
        greatest(
          coalesce(b.quantity_received,0)
          - coalesce(b.quantity_consumed,0)
          - coalesce(b.quantity_transferred,0),
          0
        )
      )
      from public.batches b
      where b.item_id::text = p_item_id::text
        and b.warehouse_id = p_warehouse_id
        and coalesce(b.status,'active') = 'active'
        and coalesce(b.qc_status,'') in ('pending','quarantined','inspected')
    ), 0),
    last_updated = now()
  where sm.item_id::text = p_item_id::text
    and sm.warehouse_id = p_warehouse_id;
end;
$$;

-- Now batch-recompute stock for ALL items in ALL warehouses
do $$
declare
  rec record;
  cnt int := 0;
begin
  for rec in
    select distinct sm.item_id, sm.warehouse_id
    from stock_management sm
  loop
    begin
      -- Temporarily bypass _require_staff by calling inner logic directly
      update stock_management sm
      set
        reserved_quantity = coalesce((
          select sum(r.quantity)
          from order_item_reservations r
          where r.item_id::text = rec.item_id::text
            and r.warehouse_id = rec.warehouse_id
        ), 0),
        available_quantity = coalesce((
          select sum(
            greatest(
              coalesce(b.quantity_received,0)
              - coalesce(b.quantity_consumed,0)
              - coalesce(b.quantity_transferred,0),
              0
            )
          )
          from batches b
          where b.item_id::text = rec.item_id::text
            and b.warehouse_id = rec.warehouse_id
            and coalesce(b.status,'active') = 'active'
            and coalesce(b.qc_status,'') = 'released'
            and not exists (
              select 1 from batch_recalls br
              where br.batch_id = b.id and br.status = 'active'
            )
            and (
              not (coalesce((select mi.category from menu_items mi where mi.id::text = rec.item_id::text),'') = 'food')
              or b.expiry_date is null
              or b.expiry_date >= current_date
            )
        ), 0),
        qc_hold_quantity = coalesce((
          select sum(
            greatest(
              coalesce(b.quantity_received,0)
              - coalesce(b.quantity_consumed,0)
              - coalesce(b.quantity_transferred,0),
              0
            )
          )
          from batches b
          where b.item_id::text = rec.item_id::text
            and b.warehouse_id = rec.warehouse_id
            and coalesce(b.status,'active') = 'active'
            and coalesce(b.qc_status,'') in ('pending','quarantined','inspected')
        ), 0),
        last_updated = now()
      where sm.item_id::text = rec.item_id::text
        and sm.warehouse_id = rec.warehouse_id;

      cnt := cnt + 1;
    exception when others then
      raise warning 'Failed to recompute %: %', rec.item_id, sqlerrm;
    end;
  end loop;
  raise notice 'Recomputed stock for % items', cnt;
end;
$$;

notify pgrst, 'reload schema';
