set app.allow_ledger_ddl = '1';

create or replace function public.get_fx_rate(p_currency text, p_date date, p_rate_type text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_currency text;
  v_type text;
  v_date date;
  v_base text;
  v_rate numeric;
  v_hi boolean := false;
  v_base_hi boolean := false;
begin
  v_currency := upper(nullif(btrim(coalesce(p_currency, '')), ''));
  v_type := lower(nullif(btrim(coalesce(p_rate_type, '')), ''));
  v_date := coalesce(p_date, current_date);
  v_base := public.get_base_currency();

  if v_type is null then
    v_type := 'operational';
  end if;
  if v_currency is null then
    v_currency := v_base;
  end if;
  if v_currency = v_base then
    return 1;
  end if;

  select fr.rate
  into v_rate
  from public.fx_rates fr
  where upper(fr.currency_code) = v_currency
    and fr.rate_type = v_type
    and fr.rate_date <= v_date
  order by fr.rate_date desc
  limit 1;

  begin
    select coalesce(c.is_high_inflation, false)
    into v_hi
    from public.currencies c
    where upper(c.code) = v_currency
    limit 1;
  exception when others then
    v_hi := false;
  end;

  begin
    select coalesce(c.is_high_inflation, false)
    into v_base_hi
    from public.currencies c
    where upper(c.code) = upper(v_base)
    limit 1;
  exception when others then
    v_base_hi := false;
  end;

  if v_rate is not null and v_rate > 0 and v_hi and not v_base_hi and v_rate > 10 then
    v_rate := 1 / v_rate;
  end if;

  return v_rate;
end;
$$;

create or replace function public.resolve_item_price(
  p_item_id text,
  p_warehouse_id uuid,
  p_currency_code text,
  p_quantity numeric,
  p_price_date date,
  p_customer_id uuid default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
  v_currency text;
  v_date date;
  v_qty numeric;
  v_price numeric;
  v_batch record;
  v_row record;
  v_fx numeric;
  v_fx_cache numeric;
  v_margin numeric := 0;
begin
  if p_item_id is null or btrim(p_item_id) = '' then
    raise exception 'p_item_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'p_warehouse_id is required';
  end if;

  v_base := public.get_base_currency();
  v_currency := upper(coalesce(nullif(btrim(p_currency_code),''), v_base));
  v_date := coalesce(p_price_date, current_date);
  v_qty := greatest(coalesce(p_quantity,1),1);

  select *
  into v_row
  from public.product_prices_multi_currency ppmc
  where ppmc.item_id = p_item_id
    and upper(ppmc.currency_code) = v_currency
    and ppmc.is_active = true
    and (ppmc.effective_from is null or ppmc.effective_from <= v_date)
    and (ppmc.effective_to is null or ppmc.effective_to >= v_date)
  order by coalesce(ppmc.effective_from, v_date) desc, ppmc.updated_at desc
  limit 1;

  select *
  into v_batch
  from public.batches b
  where b.item_id = p_item_id
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status,'active')='active'
    and coalesce(b.qc_status,'released')='released'
    and greatest(
      coalesce(b.quantity_received,0)
      - coalesce(b.quantity_consumed,0)
      - coalesce(b.quantity_transferred,0),0) > 0
  order by b.expiry_date asc nulls last, b.created_at asc
  limit 1;

  if v_batch.id is null then
    return null;
  end if;

  if found and v_row is not null then
    v_margin := coalesce(v_row.margin_percent, 0);

    if v_row.pricing_method in ('FIXED','MANUAL_OVERRIDE') then
      v_price := coalesce(v_row.price_value, null);
      if v_price is not null and v_price >= 0 then
        return round(v_price, 4);
      end if;
    elsif v_row.pricing_method = 'FOREIGN_COST_PLUS_MARGIN' then
      if v_batch.foreign_currency is null then
        return null;
      end if;
      v_price := coalesce(v_batch.foreign_unit_cost, 0) * (1 + (v_margin/100));
      if upper(v_currency) = upper(v_batch.foreign_currency) then
        return round(v_price, 4);
      end if;
      if v_batch.fx_rate_at_receipt is null or v_batch.fx_rate_at_receipt <= 0 then
        return null;
      end if;
      v_price := v_price * v_batch.fx_rate_at_receipt;
      if upper(v_currency) = upper(v_base) then
        return round(v_price, 4);
      end if;
      if v_fx_cache is null then
        v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
      end if;
      v_fx := v_fx_cache;
      if v_fx is null or v_fx <= 0 then
        return null;
      end if;
      return round(v_price / v_fx, 4);
    elsif v_row.pricing_method = 'BASE_PLUS_MARGIN' then
      v_price := coalesce(v_batch.cost_per_unit, 0) * (1 + (v_margin/100));
      if upper(v_currency) = upper(v_base) then
        return round(v_price, 4);
      end if;
      if v_fx_cache is null then
        v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
      end if;
      v_fx := v_fx_cache;
      if v_fx is null or v_fx <= 0 then
        return null;
      end if;
      return round(v_price / v_fx, 4);
    elsif v_row.pricing_method = 'LIVE_FX_BASE' then
      if public.is_production_environment() then
        raise exception 'LIVE_FX_BASE disabled in production';
      end if;
      v_price := public.get_item_price_with_discount(p_item_id, p_customer_id, v_qty);
      if upper(v_currency) = upper(v_base) then
        return round(v_price, 4);
      end if;
      if v_fx_cache is null then
        v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
      end if;
      v_fx := v_fx_cache;
      if v_fx is null or v_fx <= 0 then
        return null;
      end if;
      return round(v_price / v_fx, 4);
    end if;
  end if;

  v_price := public.get_item_price_with_discount(p_item_id, p_customer_id, v_qty);
  if upper(v_currency) = upper(v_base) then
    return round(v_price, 4);
  end if;
  if v_fx_cache is null then
    v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
  end if;
  v_fx := v_fx_cache;
  if v_fx is null or v_fx <= 0 then
    return null;
  end if;
  return round(v_price / v_fx, 4);
end;
$$;

create or replace function public.resolve_item_price_for_batch(
  p_item_id text,
  p_warehouse_id uuid,
  p_currency_code text,
  p_quantity numeric,
  p_price_date date,
  p_customer_id uuid default null,
  p_batch_id uuid default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
  v_currency text;
  v_date date;
  v_qty numeric;
  v_price numeric;
  v_batch record;
  v_row record;
  v_fx numeric;
  v_fx_cache numeric;
  v_margin numeric := 0;
  v_brow record;
begin
  if p_item_id is null or btrim(p_item_id) = '' then
    raise exception 'p_item_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'p_warehouse_id is required';
  end if;

  v_base := public.get_base_currency();
  v_currency := upper(coalesce(nullif(btrim(p_currency_code),''), v_base));
  v_date := coalesce(p_price_date, current_date);
  v_qty := greatest(coalesce(p_quantity,1),1);

  if p_batch_id is not null then
    select *
    into v_batch
    from public.batches b
    where b.id = p_batch_id
      and b.item_id = p_item_id
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status,'active')='active'
      and coalesce(b.qc_status,'released')='released'
      and greatest(
        coalesce(b.quantity_received,0)
        - coalesce(b.quantity_consumed,0)
        - coalesce(b.quantity_transferred,0),0) > 0
    limit 1;
  else
    select *
    into v_batch
    from public.batches b
    where b.item_id = p_item_id
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status,'active')='active'
      and coalesce(b.qc_status,'released')='released'
      and greatest(
        coalesce(b.quantity_received,0)
        - coalesce(b.quantity_consumed,0)
        - coalesce(b.quantity_transferred,0),0) > 0
    order by b.expiry_date asc nulls last, b.created_at asc
    limit 1;
  end if;

  if v_batch.id is null then
    return null;
  end if;

  select *
  into v_brow
  from public.batch_prices_multi_currency bpmc
  where bpmc.batch_id = v_batch.id
    and upper(bpmc.currency_code) = v_currency
    and bpmc.is_active = true
    and (bpmc.effective_from is null or bpmc.effective_from <= v_date)
    and (bpmc.effective_to is null or bpmc.effective_to >= v_date)
  order by coalesce(bpmc.effective_from, v_date) desc, bpmc.updated_at desc
  limit 1;

  if found and v_brow is not null then
    if v_brow.pricing_method in ('FIXED','MANUAL_OVERRIDE') then
      v_price := coalesce(v_brow.price_value, null);
      if v_price is not null and v_price >= 0 then
        return round(v_price, 4);
      end if;
    end if;
  end if;

  select *
  into v_row
  from public.product_prices_multi_currency ppmc
  where ppmc.item_id = p_item_id
    and upper(ppmc.currency_code) = v_currency
    and ppmc.is_active = true
    and (ppmc.effective_from is null or ppmc.effective_from <= v_date)
    and (ppmc.effective_to is null or ppmc.effective_to >= v_date)
  order by coalesce(ppmc.effective_from, v_date) desc, ppmc.updated_at desc
  limit 1;

  if found and v_row is not null then
    v_margin := coalesce(v_row.margin_percent, 0);

    if v_row.pricing_method in ('FIXED','MANUAL_OVERRIDE') then
      v_price := coalesce(v_row.price_value, null);
      if v_price is not null and v_price >= 0 then
        return round(v_price, 4);
      end if;
    elsif v_row.pricing_method = 'FOREIGN_COST_PLUS_MARGIN' then
      if v_batch.foreign_currency is null then
        return null;
      end if;
      v_price := coalesce(v_batch.foreign_unit_cost, 0) * (1 + (v_margin/100));
      if upper(v_currency) = upper(v_batch.foreign_currency) then
        return round(v_price, 4);
      end if;
      if v_batch.fx_rate_at_receipt is null or v_batch.fx_rate_at_receipt <= 0 then
        return null;
      end if;
      v_price := v_price * v_batch.fx_rate_at_receipt;
      if upper(v_currency) = upper(v_base) then
        return round(v_price, 4);
      end if;
      if v_fx_cache is null then
        v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
      end if;
      v_fx := v_fx_cache;
      if v_fx is null or v_fx <= 0 then
        return null;
      end if;
      return round(v_price / v_fx, 4);
    elsif v_row.pricing_method = 'BASE_PLUS_MARGIN' then
      v_price := coalesce(v_batch.cost_per_unit, 0) * (1 + (v_margin/100));
      if upper(v_currency) = upper(v_base) then
        return round(v_price, 4);
      end if;
      if v_fx_cache is null then
        v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
      end if;
      v_fx := v_fx_cache;
      if v_fx is null or v_fx <= 0 then
        return null;
      end if;
      return round(v_price / v_fx, 4);
    elsif v_row.pricing_method = 'LIVE_FX_BASE' then
      if public.is_production_environment() then
        raise exception 'LIVE_FX_BASE disabled in production';
      end if;
      v_price := public.get_item_price_with_discount(p_item_id, p_customer_id, v_qty);
      if upper(v_currency) = upper(v_base) then
        return round(v_price, 4);
      end if;
      if v_fx_cache is null then
        v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
      end if;
      v_fx := v_fx_cache;
      if v_fx is null or v_fx <= 0 then
        return null;
      end if;
      return round(v_price / v_fx, 4);
    end if;
  end if;

  v_price := public.get_item_price_with_discount(p_item_id, p_customer_id, v_qty);
  if upper(v_currency) = upper(v_base) then
    return round(v_price, 4);
  end if;
  if v_fx_cache is null then
    v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
  end if;
  v_fx := v_fx_cache;
  if v_fx is null or v_fx <= 0 then
    return null;
  end if;
  return round(v_price / v_fx, 4);
end;
$$;

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

create or replace function public.get_fefo_pricing(
  p_item_id text,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_customer_id uuid default null,
  p_currency_code text default null
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
language sql
security definer
set search_path = public
as $$
  select * from public.get_fefo_pricing(
    p_item_id,
    p_warehouse_id,
    p_quantity,
    p_customer_id,
    p_currency_code,
    null::uuid
  );
$$;

create or replace function public.get_fefo_pricing(
  p_item_id uuid,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_customer_id uuid default null
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
language sql
security definer
set search_path = public
as $$
  select * from public.get_fefo_pricing(
    p_item_id::text,
    p_warehouse_id,
    p_quantity,
    p_customer_id,
    public.get_base_currency(),
    null::uuid
  );
$$;

create or replace function public.get_fefo_pricing(
  p_item_id uuid,
  p_warehouse_id uuid,
  p_quantity numeric
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
language sql
security definer
set search_path = public
as $$
  select * from public.get_fefo_pricing(
    p_item_id::text,
    p_warehouse_id,
    p_quantity,
    null::uuid,
    public.get_base_currency(),
    null::uuid
  );
$$;

revoke all on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) from public;
revoke all on function public.resolve_item_price_for_batch(text, uuid, text, numeric, date, uuid, uuid) from public;
revoke all on function public.get_fefo_pricing(text, uuid, numeric, uuid, text, uuid) from public;
revoke all on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) from public;
revoke all on function public.get_fefo_pricing(uuid, uuid, numeric, uuid) from public;
revoke all on function public.get_fefo_pricing(uuid, uuid, numeric) from public;

grant execute on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) to anon, authenticated;
grant execute on function public.resolve_item_price_for_batch(text, uuid, text, numeric, date, uuid, uuid) to anon, authenticated;
grant execute on function public.get_fefo_pricing(text, uuid, numeric, uuid, text, uuid) to authenticated;
grant execute on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) to authenticated;
grant execute on function public.get_fefo_pricing(uuid, uuid, numeric, uuid) to authenticated;
grant execute on function public.get_fefo_pricing(uuid, uuid, numeric) to authenticated;

notify pgrst, 'reload schema';
