set app.allow_ledger_ddl = '1';

do $$
begin
  if not exists (select 1 from pg_type where typname = 'pricing_method_enum') then
    create type public.pricing_method_enum as enum (
      'FIXED',
      'BASE_PLUS_MARGIN',
      'FOREIGN_COST_PLUS_MARGIN',
      'LIVE_FX_BASE',
      'MANUAL_OVERRIDE'
    );
  end if;
end $$;

create table if not exists public.batch_prices_multi_currency (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.batches(id) on delete cascade,
  currency_code text not null references public.currencies(code),
  pricing_method public.pricing_method_enum not null default 'MANUAL_OVERRIDE',
  price_value numeric,
  is_active boolean not null default true,
  effective_from date,
  effective_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bpmc_price_value_check check (price_value is null or price_value >= 0)
);

create index if not exists idx_bpmc_batch_currency_active on public.batch_prices_multi_currency(batch_id, currency_code, is_active);
create unique index if not exists uq_bpmc_active_unique
on public.batch_prices_multi_currency(batch_id, upper(currency_code))
where is_active = true;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then
    create extension if not exists btree_gist;
  end if;
end $$;

alter table public.batch_prices_multi_currency
  drop constraint if exists bpmc_no_overlap;
alter table public.batch_prices_multi_currency
  add constraint bpmc_no_overlap
  exclude using gist (
    batch_id with =,
    upper(currency_code) with =,
    daterange(
      coalesce(effective_from, '1900-01-01'),
      coalesce(effective_to, '2999-12-31'),
      '[]'
    ) with &&
  )
  where (is_active = true);

alter table public.batch_prices_multi_currency enable row level security;
do $$
begin
  begin drop policy if exists bpmc_select_staff on public.batch_prices_multi_currency; exception when undefined_object then null; end;
  begin drop policy if exists bpmc_manage_admin on public.batch_prices_multi_currency; exception when undefined_object then null; end;
end $$;
create policy bpmc_select_staff on public.batch_prices_multi_currency for select using (public.is_staff());
create policy bpmc_manage_admin on public.batch_prices_multi_currency for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.upsert_batch_currency_price_admin(
  p_batch_id uuid,
  p_currency_code text,
  p_price_value numeric,
  p_effective_from date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_cur text;
  v_from date;
begin
  if not (public.is_admin() or public.has_admin_permission('prices.manage')) then
    raise exception 'not allowed';
  end if;
  if p_batch_id is null then
    raise exception 'batch required';
  end if;
  v_cur := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  v_from := coalesce(p_effective_from, current_date);
  if v_cur is null then
    raise exception 'currency required';
  end if;
  if p_price_value is null or p_price_value < 0 then
    raise exception 'price must be >= 0';
  end if;

  update public.batch_prices_multi_currency
  set is_active = false, updated_at = now()
  where batch_id = p_batch_id
    and upper(currency_code) = v_cur
    and is_active = true;

  insert into public.batch_prices_multi_currency(
    batch_id, currency_code, pricing_method, price_value, is_active, effective_from
  )
  values (
    p_batch_id, v_cur, 'MANUAL_OVERRIDE', p_price_value, true, v_from
  )
  returning id into v_id;

  begin
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
    values (
      'upsert',
      'batch_prices',
      concat(p_batch_id::text, ' ', v_cur, ' = ', p_price_value::text),
      auth.uid(),
      now(),
      jsonb_build_object('batchId', p_batch_id::text, 'currency', v_cur, 'price', p_price_value, 'effective_from', v_from::text)
    );
  exception when others then
    null;
  end;

  return v_id;
end;
$$;
revoke all on function public.upsert_batch_currency_price_admin(uuid, text, numeric, date) from public;
revoke execute on function public.upsert_batch_currency_price_admin(uuid, text, numeric, date) from anon;
grant execute on function public.upsert_batch_currency_price_admin(uuid, text, numeric, date) to authenticated;

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

revoke all on function public.resolve_item_price_for_batch(text, uuid, text, numeric, date, uuid, uuid) from public;
grant execute on function public.resolve_item_price_for_batch(text, uuid, text, numeric, date, uuid, uuid) to anon, authenticated;

do $$
begin
  begin
    drop function if exists public.get_fefo_pricing(text, uuid, numeric, uuid, text);
  exception when others then
    null;
  end;
end $$;

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
  v_batch record;
  v_next record;
  v_price numeric := 0;
  v_total_released numeric := 0;
  v_has_nonexpired_unreleased boolean := false;
  v_currency text;
  v_base text;
  v_fx numeric;
  v_min_base numeric := 0;
  v_min_cur numeric := 0;
  v_next_min_base numeric;
  v_next_min_cur numeric;
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

  if p_batch_id is not null then
    select
      b.id,
      b.cost_per_unit,
      b.min_selling_price,
      b.batch_code,
      b.expiry_date,
      greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as remaining
    into v_batch
    from public.batches b
    where b.id = p_batch_id
      and b.item_id::text = p_item_id::text
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status, 'active') = 'active'
      and (b.expiry_date is null or b.expiry_date >= current_date)
      and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
      and coalesce(b.qc_status,'released') = 'released'
    limit 1;
  else
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

  v_price := public.resolve_item_price_for_batch(
    p_item_id::text,
    p_warehouse_id,
    v_currency,
    v_qty,
    current_date,
    p_customer_id,
    v_batch.id
  );

  v_min_base := coalesce(v_batch.min_selling_price, 0);
  if upper(v_currency) = upper(v_base) then
    v_min_cur := v_min_base;
  else
    if v_fx is null or v_fx <= 0 then
      v_min_cur := 0;
    else
      v_min_cur := v_min_base / v_fx;
    end if;
  end if;

  batch_id := v_batch.id;
  unit_cost := coalesce(v_batch.cost_per_unit, 0);
  min_price := coalesce(v_min_cur, 0);
  suggested_price := greatest(coalesce(v_price, 0), coalesce(v_min_cur, 0));
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

create or replace function public.reserve_stock_for_order(
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
  v_requested numeric;
  v_needed numeric;
  v_is_food boolean;
  v_batch record;
  v_reserved_other numeric;
  v_free numeric;
  v_alloc numeric;
  v_item_batch_text text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_order_id is null or p_warehouse_id is null then
    raise exception 'order_id and warehouse_id are required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_item_id := coalesce(nullif(v_item->>'itemId',''), nullif(v_item->>'id',''));
    v_requested := coalesce(nullif(v_item->>'quantity','')::numeric, nullif(v_item->>'qty','')::numeric, 0);
    v_item_batch_text := nullif(v_item->>'batchId', '');
    if v_item_id is null or v_item_id = '' or v_requested <= 0 then
      continue;
    end if;

    select (coalesce(mi.category,'') = 'food')
    into v_is_food
    from public.menu_items mi
    where mi.id::text = v_item_id::text;

    delete from public.order_item_reservations r
    where r.order_id = p_order_id
      and r.item_id = v_item_id::text
      and r.warehouse_id = p_warehouse_id
      and (v_item_batch_text is null or r.batch_id = v_item_batch_text::uuid);

    v_needed := v_requested;

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
        and b.warehouse_id = p_warehouse_id
        and coalesce(b.status, 'active') = 'active'
        and coalesce(b.qc_status,'') = 'released'
        and not exists (
          select 1 from public.batch_recalls br
          where br.batch_id = b.id and br.status = 'active'
        )
        and (
          not coalesce(v_is_food, false)
          or (b.expiry_date is not null and b.expiry_date >= current_date)
        )
      for update;

      if not found then
        raise exception 'Batch % not found for item % in warehouse %', v_item_batch_text, v_item_id, p_warehouse_id;
      end if;

      select coalesce(sum(r2.quantity), 0)
      into v_reserved_other
      from public.order_item_reservations r2
      where r2.batch_id = v_batch.batch_id
        and r2.warehouse_id = p_warehouse_id
        and r2.order_id <> p_order_id;

      v_free := greatest(coalesce(v_batch.remaining_qty, 0) - coalesce(v_reserved_other, 0), 0);
      if v_free + 1e-9 < v_needed then
        raise exception 'INSUFFICIENT_BATCH_STOCK_FOR_ITEM_%', v_item_id;
      end if;

      v_alloc := least(v_needed, v_free);
      if v_alloc > 0 then
        insert into public.order_item_reservations(order_id, item_id, warehouse_id, batch_id, quantity, created_at, updated_at)
        values (p_order_id, v_item_id::text, p_warehouse_id, v_batch.batch_id, v_alloc, now(), now());
        v_needed := v_needed - v_alloc;
      end if;

      if v_needed > 0 then
        raise exception 'INSUFFICIENT_BATCH_STOCK_FOR_ITEM_%', v_item_id;
      end if;
    else
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
          and b.warehouse_id = p_warehouse_id
          and coalesce(b.status, 'active') = 'active'
          and coalesce(b.qc_status,'') = 'released'
          and not exists (
            select 1 from public.batch_recalls br
            where br.batch_id = b.id and br.status = 'active'
          )
          and (
            not coalesce(v_is_food, false)
            or (b.expiry_date is not null and b.expiry_date >= current_date)
          )
        order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
        for update
      loop
        exit when v_needed <= 0;
        if coalesce(v_batch.remaining_qty, 0) <= 0 then
          continue;
        end if;

        select coalesce(sum(r2.quantity), 0)
        into v_reserved_other
        from public.order_item_reservations r2
        where r2.batch_id = v_batch.batch_id
          and r2.warehouse_id = p_warehouse_id
          and r2.order_id <> p_order_id;

        v_free := greatest(coalesce(v_batch.remaining_qty, 0) - coalesce(v_reserved_other, 0), 0);
        if v_free <= 0 then
          continue;
        end if;

        v_alloc := least(v_needed, v_free);
        if v_alloc <= 0 then
          continue;
        end if;

        insert into public.order_item_reservations(order_id, item_id, warehouse_id, batch_id, quantity, created_at, updated_at)
        values (p_order_id, v_item_id::text, p_warehouse_id, v_batch.batch_id, v_alloc, now(), now());

        v_needed := v_needed - v_alloc;
      end loop;

      if v_needed > 0 then
        raise exception 'INSUFFICIENT_FEFO_BATCH_STOCK_FOR_ITEM_%', v_item_id;
      end if;
    end if;

    update public.stock_management sm
    set reserved_quantity = coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          where r.item_id = v_item_id::text
            and r.warehouse_id = p_warehouse_id
        ), 0),
        available_quantity = coalesce((
          select sum(
            greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          )
          from public.batches b
          where b.item_id::text = v_item_id::text
            and b.warehouse_id = p_warehouse_id
            and coalesce(b.status,'active') = 'active'
            and coalesce(b.qc_status,'') = 'released'
            and not exists (
              select 1 from public.batch_recalls br
              where br.batch_id = b.id and br.status = 'active'
            )
            and (
              not coalesce(v_is_food, false)
              or (b.expiry_date is not null and b.expiry_date >= current_date)
            )
        ), 0),
        last_updated = now(),
        updated_at = now()
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = p_warehouse_id;
  end loop;
end;
$$;

revoke all on function public.reserve_stock_for_order(jsonb, uuid, uuid) from public;
grant execute on function public.reserve_stock_for_order(jsonb, uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
