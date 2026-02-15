set app.allow_ledger_ddl = '1';

create extension if not exists btree_gist;

do $$
begin
  if to_regclass('public.batches') is not null then
    alter table public.batches
      add column if not exists foreign_currency text,
      add column if not exists foreign_unit_cost numeric,
      add column if not exists fx_rate_at_receipt numeric,
      add column if not exists fx_rate_date date;
  end if;
end $$;

create unique index if not exists uq_ppmc_active_unique
on public.product_prices_multi_currency(item_id, upper(currency_code))
where is_active = true;

alter table public.product_prices_multi_currency
  drop constraint if exists ppmc_no_overlap;
alter table public.product_prices_multi_currency
  add constraint ppmc_no_overlap
  exclude using gist (
    item_id with =,
    upper(currency_code) with =,
    daterange(
      coalesce(effective_from, '1900-01-01'),
      coalesce(effective_to, '2999-12-31'),
      '[]'
    ) with &&
  )
  where (is_active = true);

create index if not exists idx_batches_fefo_lookup
on public.batches(item_id, warehouse_id, status, qc_status, expiry_date);

create or replace function public.prevent_foreign_cost_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.foreign_unit_cost is distinct from new.foreign_unit_cost then
    raise exception 'foreign_unit_cost cannot be modified after insert';
  end if;
  return new;
end;
$$;

do $$
begin
  if to_regclass('public.batches') is not null then
    drop trigger if exists trg_lock_foreign_snapshot on public.batches;
    create trigger trg_lock_foreign_snapshot
    before update on public.batches
    for each row
    when (old.foreign_unit_cost is not null)
    execute function public.prevent_foreign_cost_update();
  end if;
end $$;

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
  v_foreign_cost numeric;
  v_enabled boolean;
  v_margin numeric;
  v_fx_source public.pricing_fx_source_enum;
  v_fallback_base numeric;
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
        if v_fx_source = 'OPERATIONAL' then
          v_fx := public.get_fx_rate(v_currency, v_date, 'operational');
        elsif v_fx_source = 'ACCOUNTING' then
          v_fx := public.get_fx_rate(v_currency, v_date, 'accounting');
        elsif v_fx_source = 'PURCHASE_SNAPSHOT' then
          select nullif(po.fx_rate, 0)
          into v_fx
          from public.purchase_items pi
          join public.purchase_orders po on po.id = pi.purchase_order_id
          where pi.item_id = p_item_id
            and upper(coalesce(po.currency, '')) = v_currency
          order by po.created_at desc
          limit 1;
          if v_fx is null then
            v_fx := public.get_fx_rate(v_currency, v_date, 'operational');
          end if;
        else
          v_fx := null;
        end if;
        if v_fx is null or v_fx <= 0 then
          raise exception 'FX rate not available for currency % on %', v_currency, v_date;
        end if;
        return round(v_price / v_fx, 4);
      elsif v_row.pricing_method = 'FOREIGN_COST_PLUS_MARGIN' then
        select nullif(b.foreign_unit_cost, 0)
        into v_foreign_cost
        from public.batches b
        where b.item_id = p_item_id
          and b.warehouse_id is not null
          and coalesce(b.status,'active')='active'
          and coalesce(b.qc_status,'released')='released'
          and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0),0) > 0
        order by b.expiry_date asc nulls last, b.created_at asc
        limit 1;
        if v_foreign_cost is not null and v_foreign_cost > 0 then
          v_price := v_foreign_cost * (1 + (greatest(v_margin, 0) / 100));
          return round(v_price, 4);
        end if;
        select coalesce(mi.cost_price, 0), coalesce(mi.buying_price, 0)
        into v_cost_base, v_fallback_cost
        from public.menu_items mi
        where mi.id = p_item_id;
        if v_cost_base is null or v_cost_base <= 0 then
          v_cost_base := coalesce(v_fallback_cost, 0);
        end if;
        v_fallback_base := coalesce(v_cost_base, 0) * (1 + (greatest(v_margin, 0) / 100));
        if upper(v_currency) = upper(v_base) then
          return round(v_fallback_base, 4);
        end if;
        if v_fx_source = 'OPERATIONAL' then
          v_fx := public.get_fx_rate(v_currency, v_date, 'operational');
        elsif v_fx_source = 'ACCOUNTING' then
          v_fx := public.get_fx_rate(v_currency, v_date, 'accounting');
        elsif v_fx_source = 'PURCHASE_SNAPSHOT' then
          select nullif(po.fx_rate, 0)
          into v_fx
          from public.purchase_items pi
          join public.purchase_orders po on po.id = pi.purchase_order_id
          where pi.item_id = p_item_id
            and upper(coalesce(po.currency, '')) = v_currency
          order by po.created_at desc
          limit 1;
          if v_fx is null then
            v_fx := public.get_fx_rate(v_currency, v_date, 'operational');
          end if;
        else
          v_fx := null;
        end if;
        if v_fx is null or v_fx <= 0 then
          raise exception 'FX rate not available for currency % on %', v_currency, v_date;
        end if;
        return round(v_fallback_base / v_fx, 4);
      elsif v_row.pricing_method = 'LIVE_FX_BASE' then
        v_price := public.get_item_price_with_discount(p_item_id, p_customer_id, v_qty);
        if upper(v_currency) = upper(v_base) then
          return round(v_price, 4);
        end if;
        v_fx := public.get_fx_rate(v_currency, v_date, 'operational');
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
  v_fx := public.get_fx_rate(v_currency, v_date, 'operational');
  if v_fx is null or v_fx <= 0 then
    raise exception 'FX rate not available for currency % on %', v_currency, v_date;
  end if;
  return round(v_price / v_fx, 4);
end;
$$;

create or replace function public.resolve_item_price(
  p_item_id text,
  p_currency_code text,
  p_quantity numeric,
  p_price_date date
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.resolve_item_price(p_item_id, p_currency_code, p_quantity, p_price_date, null);
end;
$$;

revoke all on function public.resolve_item_price(text, text, numeric, date) from public;
revoke all on function public.resolve_item_price(text, text, numeric, date, uuid) from public;
grant execute on function public.resolve_item_price(text, text, numeric, date) to anon, authenticated;
grant execute on function public.resolve_item_price(text, text, numeric, date, uuid) to anon, authenticated;

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
  order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
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
