-- ============================================================================
-- Repair: recompute return status for ALL orders that have completed returns
-- This fixes orders where returnStatus was not set or silently failed
-- ============================================================================

-- First, make the function more robust by removing error swallowing
create or replace function public.recompute_order_return_status(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_total_qty numeric := 0;
  v_returned_qty numeric := 0;
  v_any_return boolean := false;
  v_status text := null;
  v_existing_returned_at timestamptz := null;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    return;
  end if;

  begin
    v_existing_returned_at := (v_order.data->>'returnedAt')::timestamptz;
  exception when others then
    v_existing_returned_at := null;
  end;

  -- Get total sold quantity from order items
  begin
    select coalesce(sum( (item->>'quantity')::numeric ), 0)
    into v_total_qty
    from jsonb_array_elements(coalesce(v_order.data->'items', '[]'::jsonb)) item;
  exception when others then
    v_total_qty := 0;
  end;

  -- Get total returned quantity from completed sales returns
  begin
    select coalesce(sum( (ri->>'quantity')::numeric ), 0)
    into v_returned_qty
    from public.sales_returns sr
    cross join lateral jsonb_array_elements(coalesce(sr.items, '[]'::jsonb)) ri
    where sr.order_id = p_order_id
      and sr.status = 'completed';
  exception when others then
    v_returned_qty := 0;
  end;

  select exists(
    select 1 from public.sales_returns
    where order_id = p_order_id
      and status = 'completed'
  )
  into v_any_return;

  if not v_any_return then
    update public.orders
    set data = coalesce(data, '{}'::jsonb) - 'returnStatus' - 'returnedAt' - 'returnUpdatedAt'
    where id = p_order_id;
    return;
  end if;

  if v_total_qty <= 0 then
    v_status := 'partial';
  elsif v_returned_qty >= v_total_qty then
    v_status := 'full';
  else
    v_status := 'partial';
  end if;

  update public.orders
  set data = jsonb_set(
    jsonb_set(
      jsonb_set(
        coalesce(data, '{}'::jsonb),
        '{returnStatus}',
        to_jsonb(v_status),
        true
      ),
      '{returnedAt}',
      to_jsonb(coalesce(v_existing_returned_at, now())),
      true
    ),
    '{returnUpdatedAt}',
    to_jsonb(now()),
    true
  )
  where id = p_order_id;
end;
$$;

-- Now batch-recompute for ALL orders that have completed sales returns
do $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select distinct sr.order_id
    from public.sales_returns sr
    where sr.status = 'completed'
      and sr.order_id is not null
  loop
    begin
      perform public.recompute_order_return_status(r.order_id);
      v_count := v_count + 1;
    exception when others then
      raise notice 'Failed to recompute return status for order %: %', r.order_id, sqlerrm;
    end;
  end loop;
  raise notice 'Recomputed return status for % orders', v_count;
end $$;

notify pgrst, 'reload schema';
