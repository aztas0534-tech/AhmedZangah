create or replace function public.resolve_item_price(
  p_item_id text,
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
  v_row record;
  v_cost_base numeric;
  v_fallback_cost numeric;
  v_fx numeric;
  v_fx_cache numeric;
  v_foreign_cost numeric;
  v_enabled boolean;
  v_margin numeric;
  v_fx_source public.pricing_fx_source_enum;
  v_fallback_base numeric;
  v_batch_currency text;
  v_batch_fx numeric;
begin
  if p_item_id is null or btrim(p_item_id) = '' then
    raise exception 'p_item_id is required';
  end if;
  v_base := public.get_base_currency();
  v_currency := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  if v_currency is null then
    v_currency := v_base;
  end if;
  v_date := coalesce(p_price_date, current_date);
  v_qty := coalesce(p_quantity, 1);
  if v_qty <= 0 then
    v_qty := 1;
  end if;

  v_enabled := public.is_multi_currency_pricing_enabled();
  if v_enabled then
    select *
    into v_row
    from public.product_prices_multi_currency ppmc
    where ppmc.item_id = p_item_id
      and upper(ppmc.currency_code) = v_currency
      and ppmc.is_active = true
      and (ppmc.effective_from is null or ppmc.effective_from <= v_date)
      and (ppmc.effective_to is null or ppmc.effective_to >= v_date)
    order by coalesce(ppmc.effective_from, v_date) desc, ppmc.updated_at desc, ppmc.created_at desc
    limit 1;

    if found then
      v_margin := coalesce(v_row.margin_percent, 0);
      v_fx_source := coalesce(v_row.fx_source, 'NONE');

      if v_row.pricing_method in ('FIXED','MANUAL_OVERRIDE') then
        v_price := coalesce(v_row.price_value, null);
        if v_price is not null and v_price >= 0 then
          return round(v_price, 4);
        end if;
      elsif v_row.pricing_method = 'BASE_PLUS_MARGIN' then
        select coalesce(mi.cost_price, 0), coalesce(mi.buying_price, 0)
        into v_cost_base, v_fallback_cost
        from public.menu_items mi
        where mi.id = p_item_id;
        if v_cost_base is null or v_cost_base <= 0 then
          v_cost_base := coalesce(v_fallback_cost, 0);
        end if;
        v_price := coalesce(v_cost_base, 0) * (1 + (greatest(v_margin, 0) / 100));
        if upper(v_currency) = upper(v_base) then
          return round(v_price, 4);
        end if;
        select b.fx_rate_at_receipt, upper(coalesce(b.foreign_currency, ''))
        into v_fx, v_batch_currency
        from public.batches b
        where b.item_id = p_item_id
          and coalesce(b.status,'active')='active'
          and coalesce(b.qc_status,'released')='released'
          and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0),0) > 0
        order by b.expiry_date asc nulls last, b.created_at asc
        limit 1;
        if v_fx is not null and v_fx > 0 and v_batch_currency is not null and v_batch_currency <> '' and upper(v_batch_currency) = upper(v_currency) then
          return round(v_price / v_fx, 4);
        end if;
        if v_fx_cache is null then
          v_fx_cache := public.get_fx_rate(v_currency, v_date, 'operational');
        end if;
        v_fx := v_fx_cache;
        if v_fx is null or v_fx <= 0 then
          raise exception 'FX rate not available for currency % on %', v_currency, v_date;
        end if;
        return round(v_price / v_fx, 4);
      elsif v_row.pricing_method = 'FOREIGN_COST_PLUS_MARGIN' then
        select
          b.foreign_unit_cost,
          upper(b.foreign_currency),
          b.fx_rate_at_receipt
        into
          v_foreign_cost,
          v_batch_currency,
          v_batch_fx
        from public.batches b
        where b.item_id = p_item_id
          and coalesce(b.status,'active')='active'
          and coalesce(b.qc_status,'released')='released'
          and greatest(
              coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),0) > 0
        order by b.expiry_date asc nulls last, b.created_at asc
        limit 1;

        if v_batch_currency is null then
          raise exception 'Batch currency undefined for item %', p_item_id;
        end if;

        if v_foreign_cost is not null and v_foreign_cost > 0 then
          v_price := v_foreign_cost * (1 + (greatest(v_margin,0)/100));

          if upper(v_currency) = upper(v_batch_currency) then
            return round(v_price,4);
          end if;

          if v_batch_fx is null or v_batch_fx <= 0 then
            raise exception 'Batch FX snapshot missing for item %', p_item_id;
          end if;

          if upper(v_batch_currency) = upper(v_base) then
            if v_fx_cache is null then
              v_fx_cache := public.get_fx_rate(v_currency,v_date,'operational');
            end if;
            v_fx := v_fx_cache;
            if v_fx is null or v_fx <= 0 then
              raise exception 'FX rate not available for %', v_currency;
            end if;
            return round(v_price / v_fx,4);
          else
            v_price := v_price * v_batch_fx;

            if upper(v_currency) = upper(v_base) then
              return round(v_price,4);
            end if;

            if v_fx_cache is null then
              v_fx_cache := public.get_fx_rate(v_currency,v_date,'operational');
            end if;
            v_fx := v_fx_cache;
            if v_fx is null or v_fx <= 0 then
              raise exception 'FX rate not available for %', v_currency;
            end if;

            return round(v_price / v_fx,4);
          end if;
        end if;
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
          raise exception 'FX rate not available for currency % on %', v_currency, v_date;
        end if;
        return round(v_price / v_fx, 4);
      end if;
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
    raise exception 'FX rate not available for currency % on %', v_currency, v_date;
  end if;
  v_price := v_price / v_fx;
  if v_price is null then
    raise exception 'Pricing resolution failed for item %', p_item_id;
  end if;
  return round(v_price, 4);
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

revoke all on function public.resolve_item_price(text, text, numeric, date, uuid) from public;
revoke all on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) from public;
revoke all on function public.resolve_item_price_for_batch(text, uuid, text, numeric, date, uuid, uuid) from public;
grant execute on function public.resolve_item_price(text, text, numeric, date, uuid) to anon, authenticated;
grant execute on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) to anon, authenticated;
grant execute on function public.resolve_item_price_for_batch(text, uuid, text, numeric, date, uuid, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
