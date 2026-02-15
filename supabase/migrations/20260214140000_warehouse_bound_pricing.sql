set app.allow_ledger_ddl = '1';

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
  v_margin numeric := 0;
  v_row record;
  v_fx numeric;
  v_fx_cache numeric;
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
      v_price := v_price / v_batch.fx_rate_at_receipt;
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

revoke all on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) from public;
grant execute on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) to anon, authenticated;

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
language plpgsql
security definer
set search_path = public
as $$
declare
  v_qty numeric := greatest(coalesce(p_quantity, 0), 0);
  v_batch record;
  v_next record;
  v_base_price numeric := 0;
  v_total_released numeric := 0;
  v_has_nonexpired_unreleased boolean := false;
  v_currency text;
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

  select
    b.id,
    b.cost_per_unit,
    b.min_selling_price,
    b.batch_code,
    b.expiry_date,
    greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as remaining
  into v_batch
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
    and coalesce(b.qc_status,'released') = 'released'
  order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
  limit 1;

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

  if v_batch.id is null then
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

  select coalesce(sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)), 0)
  into v_total_released
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and coalesce(b.qc_status,'released') = 'released';

  if v_total_released + 1e-9 < v_qty then
    reason_code := 'INSUFFICIENT_BATCH_QUANTITY';
  else
    reason_code := null;
  end if;

  v_currency := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  v_base_price := public.resolve_item_price(
    p_item_id::text,
    p_warehouse_id,
    coalesce(v_currency, public.get_base_currency()),
    v_qty,
    current_date,
    p_customer_id
  );

  batch_id := v_batch.id;
  unit_cost := coalesce(v_batch.cost_per_unit, 0);
  min_price := coalesce(v_batch.min_selling_price, 0);
  suggested_price := greatest(coalesce(v_base_price, 0), coalesce(v_batch.min_selling_price, 0));
  batch_code := v_batch.batch_code;
  expiry_date := v_batch.expiry_date;

  select b.min_selling_price
  into v_next
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
    and coalesce(b.qc_status,'released') = 'released'
    and b.id <> v_batch.id
  order by b.expiry_date asc nulls last, b.created_at asc
  limit 1;

  next_batch_min_price := nullif(coalesce(v_next.min_selling_price, null), null);
  warning_next_batch_price_diff :=
    case
      when next_batch_min_price is null then false
      else abs(next_batch_min_price - min_price) > 1e-9
    end;

  return next;
end;
$$;

revoke all on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) from public;
grant execute on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) to authenticated;

notify pgrst, 'reload schema';
