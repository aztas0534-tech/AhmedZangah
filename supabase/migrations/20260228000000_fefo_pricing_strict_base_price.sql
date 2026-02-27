create or replace function public.get_fefo_pricing(
  p_item_id text,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_customer_id uuid default null,
  p_currency_code text default null,
  p_batch_id uuid default null
)
returns table (
  batch_id uuid,
  unit_cost numeric,
  min_price numeric,
  suggested_price numeric,
  batch_code text,
  expiry_date date,
  next_batch_min_price numeric,
  warning_next_batch_price_diff boolean,
  reason_code text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_qty numeric := greatest(coalesce(p_quantity, 0), 0);
  v_first_id uuid;
  v_first_cost_per_unit numeric;
  v_first_batch_code text;
  v_first_expiry_date date;
  v_first_set boolean := false;
  v_step record;
  v_next record;
  v_price_required numeric := 0;
  v_total_free numeric := 0;
  v_has_nonexpired_unreleased boolean := false;
  v_currency text;
  v_base text;
  v_fx numeric;
  v_min_base_required numeric := 0;
  v_min_cur_required numeric := 0;
  v_next_min_base numeric;
  v_next_min_cur numeric;
  v_remaining_needed numeric;
  v_alloc numeric;
  v_batch_price numeric;
begin
  if nullif(btrim(coalesce(p_item_id, '')), '') is null then
    raise exception 'p_item_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'p_warehouse_id is required';
  end if;
  if v_qty <= 0 then
    v_qty := 1;
  end if;
 
  v_base := public.get_base_currency();
  v_currency := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  if v_currency is null then
    v_currency := v_base;
  end if;
  if upper(v_currency) <> upper(v_base) then
    v_fx := public.get_fx_rate(v_currency, current_date, 'operational');
  else
    v_fx := 1;
  end if;
 
  select exists(
    select 1
    from public.batches b
    where b.item_id::text = p_item_id::text
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status, 'active') = 'active'
      and (b.expiry_date is null or b.expiry_date >= current_date)
      and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
      and coalesce(b.qc_status,'released') <> 'released'
  ) into v_has_nonexpired_unreleased;
 
  if p_batch_id is not null then
    for v_step in
      select
        b.id,
        b.cost_per_unit,
        b.min_selling_price,
        b.batch_code,
        b.expiry_date,
        greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as remaining,
        coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          join public.orders o on o.id = r.order_id
          where r.batch_id = b.id
            and r.warehouse_id = p_warehouse_id
            and o.status not in ('delivered','cancelled')
        ), 0) as reserved_other,
        greatest(
          greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          - coalesce((
              select sum(r.quantity)
              from public.order_item_reservations r
              join public.orders o on o.id = r.order_id
              where r.batch_id = b.id
                and r.warehouse_id = p_warehouse_id
                and o.status not in ('delivered','cancelled')
            ), 0),
          0
        ) as free_qty
      from public.batches b
      where b.id = p_batch_id
        and b.item_id::text = p_item_id::text
        and b.warehouse_id = p_warehouse_id
        and coalesce(b.status, 'active') = 'active'
        and (b.expiry_date is null or b.expiry_date >= current_date)
        and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
        and coalesce(b.qc_status,'released') = 'released'
        and greatest(
          greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          - coalesce((
              select sum(r.quantity)
              from public.order_item_reservations r
              join public.orders o on o.id = r.order_id
              where r.batch_id = b.id
                and r.warehouse_id = p_warehouse_id
                and o.status not in ('delivered','cancelled')
            ), 0),
          0
        ) > 0
      limit 1
    loop
      v_first_id := v_step.id;
      v_first_cost_per_unit := v_step.cost_per_unit;
      v_first_batch_code := v_step.batch_code;
      v_first_expiry_date := v_step.expiry_date;
      v_first_set := true;

      v_min_base_required := greatest(coalesce(v_step.min_selling_price, 0), 0);
      v_batch_price := public.resolve_item_price_for_batch(
        p_item_id::text,
        p_warehouse_id,
        v_currency,
        v_qty,
        current_date,
        p_customer_id,
        v_step.id
      );
      v_price_required := greatest(coalesce(v_batch_price, 0), 0);
      exit;
    end loop;
  else
    v_remaining_needed := v_qty;
    for v_step in
      select
        b.id,
        b.cost_per_unit,
        b.min_selling_price,
        b.batch_code,
        b.expiry_date,
        greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as remaining,
        coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          join public.orders o on o.id = r.order_id
          where r.batch_id = b.id
            and r.warehouse_id = p_warehouse_id
            and o.status not in ('delivered','cancelled')
        ), 0) as reserved_other,
        greatest(
          greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          - coalesce((
              select sum(r.quantity)
              from public.order_item_reservations r
              join public.orders o on o.id = r.order_id
              where r.batch_id = b.id
                and r.warehouse_id = p_warehouse_id
                and o.status not in ('delivered','cancelled')
            ), 0),
          0
        ) as free_qty
      from public.batches b
      where b.item_id::text = p_item_id::text
        and b.warehouse_id = p_warehouse_id
        and coalesce(b.status, 'active') = 'active'
        and (b.expiry_date is null or b.expiry_date >= current_date)
        and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
        and coalesce(b.qc_status,'released') = 'released'
        and greatest(
          greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          - coalesce((
              select sum(r.quantity)
              from public.order_item_reservations r
              join public.orders o on o.id = r.order_id
              where r.batch_id = b.id
                and r.warehouse_id = p_warehouse_id
                and o.status not in ('delivered','cancelled')
            ), 0),
          0
        ) > 0
      order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
    loop
      exit when v_remaining_needed <= 0;
      v_alloc := least(v_remaining_needed, coalesce(v_step.free_qty, 0));
      if v_alloc <= 0 then
        continue;
      end if;
 
      if not v_first_set then
        v_first_id := v_step.id;
        v_first_cost_per_unit := v_step.cost_per_unit;
        v_first_batch_code := v_step.batch_code;
        v_first_expiry_date := v_step.expiry_date;
        v_first_set := true;
      end if;
 
      v_min_base_required := greatest(v_min_base_required, coalesce(v_step.min_selling_price, 0));
      v_batch_price := public.resolve_item_price_for_batch(
        p_item_id::text,
        p_warehouse_id,
        v_currency,
        v_qty,
        current_date,
        p_customer_id,
        v_step.id
      );
      v_price_required := greatest(v_price_required, coalesce(v_batch_price, 0));
      v_remaining_needed := v_remaining_needed - v_alloc;
    end loop;
  end if;
 
  select coalesce(sum(greatest(
    greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
    - coalesce((
        select sum(r.quantity)
        from public.order_item_reservations r
        join public.orders o on o.id = r.order_id
        where r.batch_id = b.id
          and r.warehouse_id = p_warehouse_id
          and o.status not in ('delivered','cancelled')
      ), 0),
    0
  )), 0)
  into v_total_free
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and coalesce(b.qc_status,'released') = 'released';
 
  if v_total_free + 1e-9 < v_qty then
    reason_code := 'INSUFFICIENT_BATCH_QUANTITY';
  else
    reason_code := null;
  end if;
 
  if not v_first_set then
    reason_code := case when v_has_nonexpired_unreleased then 'BATCH_NOT_RELEASED' else 'NO_VALID_BATCH' end;
    batch_id := null;
    unit_cost := 0;
    min_price := 0;
    suggested_price := 0;
    batch_code := null;
    expiry_date := null;
    next_batch_min_price := null;
    warning_next_batch_price_diff := false;
    return next;
  end if;
 
  if upper(v_currency) = upper(v_base) then
    v_min_cur_required := v_min_base_required;
  else
    if v_fx is null or v_fx <= 0 then
      v_min_cur_required := 0;
    else
      v_min_cur_required := v_min_base_required / v_fx;
    end if;
  end if;
 
  batch_id := v_first_id;
  unit_cost := coalesce(v_first_cost_per_unit, 0);
  min_price := coalesce(v_min_cur_required, 0);
  
  -- CHANGED: Use ONLY the base price, overriding the min selling price check here.
  -- The constraint will still be enforced by trg_block_sale_below_cost during checkout
  -- if the user does not have permission, but this allows the UI to show the exact
  -- managed price.
  suggested_price := coalesce(v_price_required, 0);
  
  batch_code := v_first_batch_code;
  expiry_date := v_first_expiry_date;
 
  select b.min_selling_price
  into v_next
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
    and coalesce(b.qc_status,'released') = 'released'
    and b.id <> v_first_id
    and greatest(
      greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
      - coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          join public.orders o on o.id = r.order_id
          where r.batch_id = b.id
            and r.warehouse_id = p_warehouse_id
            and o.status not in ('delivered','cancelled')
        ), 0),
      0
    ) > 0
  order by b.expiry_date asc nulls last, b.created_at asc
  limit 1;
 
  v_next_min_base := v_next.min_selling_price;
  if v_next_min_base is null then
    v_next_min_cur := null;
  else
    if upper(v_currency) = upper(v_base) then
      v_next_min_cur := v_next_min_base;
    else
      if v_fx is null or v_fx <= 0 then
        v_next_min_cur := null;
      else
        v_next_min_cur := v_next_min_base / v_fx;
      end if;
    end if;
  end if;
 
  next_batch_min_price := v_next_min_cur;
  warning_next_batch_price_diff :=
    case
      when next_batch_min_price is null then false
      else abs(next_batch_min_price - min_price) > 1e-9
    end;
 
  return next;
end;
$$;

revoke all on function public.get_fefo_pricing(text, uuid, numeric, uuid, text, uuid) from public;
grant execute on function public.get_fefo_pricing(text, uuid, numeric, uuid, text, uuid) to authenticated;

notify pgrst, 'reload schema';
