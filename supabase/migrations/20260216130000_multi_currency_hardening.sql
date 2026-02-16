-- ═══════════════════════════════════════════════════════════════════════════
-- Multi-Currency Hardening: Structural Improvements
-- ═══════════════════════════════════════════════════════════════════════════
-- This migration adds:
-- 1. FX Rate Audit Trail (table + trigger)
-- 2. CHECK constraints on batch costs
-- 3. Trigger to auto-sync cost_per_unit and min_selling_price from unit_cost
-- 4. Pricing safety guard function
-- 5. Currency rounding rules
-- ═══════════════════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 1. FX RATE AUDIT TRAIL                                                 │
-- │ Track every change to fx_rates with who, when, old/new values          │
-- └─────────────────────────────────────────────────────────────────────────┘

create table if not exists public.fx_rate_audit_log (
  id bigint generated always as identity primary key,
  fx_rate_id uuid,
  currency_code text not null,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  old_rate numeric,
  new_rate numeric,
  old_rate_date date,
  new_rate_date date,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  context text,
  metadata jsonb
);

create index if not exists idx_fx_audit_currency on public.fx_rate_audit_log(currency_code, changed_at desc);
create index if not exists idx_fx_audit_changed_at on public.fx_rate_audit_log(changed_at desc);

alter table public.fx_rate_audit_log enable row level security;

do $$
begin
  begin drop policy if exists fx_audit_select_admin on public.fx_rate_audit_log; exception when undefined_object then null; end;
  begin drop policy if exists fx_audit_insert_all on public.fx_rate_audit_log; exception when undefined_object then null; end;
end $$;

create policy fx_audit_select_admin on public.fx_rate_audit_log
  for select using (public.is_admin());
create policy fx_audit_insert_all on public.fx_rate_audit_log
  for insert with check (true);

-- Trigger function to capture FX rate changes
create or replace function public.trg_fx_rate_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.fx_rate_audit_log(fx_rate_id, currency_code, action, new_rate, new_rate_date, changed_by, context)
    values (new.id, new.currency_code, 'INSERT', new.rate, new.rate_date, auth.uid(), tg_op);
    return new;
  elsif tg_op = 'UPDATE' then
    if old.rate is distinct from new.rate or old.rate_date is distinct from new.rate_date then
      insert into public.fx_rate_audit_log(fx_rate_id, currency_code, action, old_rate, new_rate, old_rate_date, new_rate_date, changed_by, context, metadata)
      values (new.id, new.currency_code, 'UPDATE', old.rate, new.rate, old.rate_date, new.rate_date, auth.uid(), tg_op,
        jsonb_build_object('rate_change_pct', case when old.rate > 0 then round(((new.rate - old.rate) / old.rate * 100)::numeric, 2) else null end)
      );
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.fx_rate_audit_log(fx_rate_id, currency_code, action, old_rate, old_rate_date, changed_by, context)
    values (old.id, old.currency_code, 'DELETE', old.rate, old.rate_date, auth.uid(), tg_op);
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_fx_rates_audit on public.fx_rates;
create trigger trg_fx_rates_audit
  after insert or update or delete on public.fx_rates
  for each row execute function public.trg_fx_rate_audit();


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 2. CHECK CONSTRAINTS ON BATCH COSTS                                    │
-- │ Prevent unreasonable values from being stored                          │
-- └─────────────────────────────────────────────────────────────────────────┘

-- First, fix any negative values
update public.batches
set unit_cost = abs(unit_cost)
where unit_cost < 0;

update public.batches
set cost_per_unit = abs(cost_per_unit)
where cost_per_unit < 0;

update public.batches
set min_selling_price = abs(min_selling_price)
where min_selling_price < 0;

-- Add CHECK constraints - allow up to 10M SAR per unit (generous ceiling)
alter table public.batches
  drop constraint if exists chk_batch_unit_cost_range;
alter table public.batches
  add constraint chk_batch_unit_cost_range
  check (unit_cost is null or (unit_cost >= 0 and unit_cost < 10000000));

alter table public.batches
  drop constraint if exists chk_batch_cost_per_unit_range;
alter table public.batches
  add constraint chk_batch_cost_per_unit_range
  check (cost_per_unit is null or (cost_per_unit >= 0 and cost_per_unit < 10000000));

alter table public.batches
  drop constraint if exists chk_batch_min_selling_price_range;
alter table public.batches
  add constraint chk_batch_min_selling_price_range
  check (min_selling_price is null or (min_selling_price >= 0 and min_selling_price < 100000000));

alter table public.batches
  drop constraint if exists chk_batch_fx_rate_range;
alter table public.batches
  add constraint chk_batch_fx_rate_range
  check (fx_rate_at_receipt is null or (fx_rate_at_receipt > 0 and fx_rate_at_receipt < 100000));


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 3. AUTO-SYNC TRIGGER: cost_per_unit & min_selling_price from unit_cost │
-- │ Single source of truth: unit_cost controls the other two               │
-- └─────────────────────────────────────────────────────────────────────────┘

create or replace function public.trg_batch_sync_cost_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- When unit_cost changes, automatically sync cost_per_unit and min_selling_price
  if tg_op = 'UPDATE' and old.unit_cost is distinct from new.unit_cost then
    new.cost_per_unit := new.unit_cost;
    new.min_selling_price := round(
      coalesce(new.unit_cost, 0)
      * (1 + greatest(0, coalesce(new.min_margin_pct, 0)) / 100),
      4
    );
  end if;

  -- On INSERT, ensure consistency
  if tg_op = 'INSERT' then
    if new.cost_per_unit is null or new.cost_per_unit <= 0 then
      new.cost_per_unit := coalesce(new.unit_cost, 0);
    end if;
    if new.min_selling_price is null or new.min_selling_price <= 0 then
      new.min_selling_price := round(
        coalesce(new.unit_cost, 0)
        * (1 + greatest(0, coalesce(new.min_margin_pct, 0)) / 100),
        4
      );
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_batches_sync_costs on public.batches;
create trigger trg_batches_sync_costs
  before insert or update on public.batches
  for each row execute function public.trg_batch_sync_cost_fields();


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 4. CURRENCY ROUNDING RULES                                             │
-- │ Add decimal_places to currencies table for proper rounding             │
-- └─────────────────────────────────────────────────────────────────────────┘

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'currencies' and column_name = 'decimal_places'
  ) then
    alter table public.currencies add column decimal_places int not null default 2;
  end if;
end $$;

-- Set common currency decimal places
update public.currencies set decimal_places = 2 where code in ('SAR','USD','EUR','GBP','AED') and decimal_places = 2;
update public.currencies set decimal_places = 0 where code in ('YER','JPY','KRW') and decimal_places != 0;


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 5. PRICING SAFETY GUARD FUNCTION                                       │
-- │ Validates price reasonableness before returning to POS                  │
-- └─────────────────────────────────────────────────────────────────────────┘

create or replace function public.validate_price_reasonableness(
  p_price numeric,
  p_currency_code text,
  p_item_id text default null
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_max numeric;
  v_base text;
begin
  if p_price is null or p_price < 0 then
    return 0;
  end if;

  v_base := public.get_base_currency();

  -- Set maximum reasonable price per currency
  if upper(p_currency_code) = upper(v_base) then
    v_max := 1000000;  -- 1M SAR max per unit
  else
    -- For foreign currency, scale the max by estimated fx rate
    v_max := 1000000 / coalesce(nullif(public.get_fx_rate(p_currency_code, current_date, 'operational'), 0), 1);
    v_max := greatest(v_max, 1000000);  -- at least 1M in any currency
  end if;

  if p_price > v_max then
    -- Log the anomaly
    begin
      insert into public.system_audit_logs(action, module, details, performed_at, metadata)
      values (
        'PRICE_ANOMALY_DETECTED',
        'pricing',
        concat('Price ', p_price::text, ' ', p_currency_code, ' exceeds max ', v_max::text, ' for item ', coalesce(p_item_id, '?')),
        now(),
        jsonb_build_object('price', p_price, 'currency', p_currency_code, 'max', v_max, 'item_id', p_item_id)
      );
    exception when others then
      null;
    end;
    return 0;  -- Return 0 to signal error rather than allowing astronomical price
  end if;

  return p_price;
end;
$$;

revoke all on function public.validate_price_reasonableness(numeric, text, text) from public;
grant execute on function public.validate_price_reasonableness(numeric, text, text) to authenticated;


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 6. FX DIRECTION DOCUMENTATION FUNCTION                                 │
-- │ Helper to verify correct FX direction at runtime                       │
-- └─────────────────────────────────────────────────────────────────────────┘

create or replace function public.convert_currency(
  p_amount numeric,
  p_from_currency text,
  p_to_currency text,
  p_rate_date date default current_date,
  p_rate_type text default 'operational'
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base text;
  v_from text;
  v_to text;
  v_fx_from numeric;
  v_fx_to numeric;
  v_base_amount numeric;
begin
  if p_amount is null or p_amount = 0 then
    return 0;
  end if;

  v_base := upper(public.get_base_currency());
  v_from := upper(coalesce(p_from_currency, v_base));
  v_to := upper(coalesce(p_to_currency, v_base));

  if v_from = v_to then
    return p_amount;
  end if;

  -- Step 1: Convert from source to base (triangulation)
  if v_from = v_base then
    v_base_amount := p_amount;
  else
    v_fx_from := public.get_fx_rate(v_from, p_rate_date, p_rate_type);
    if v_fx_from is null or v_fx_from <= 0 then
      raise exception 'FX rate unavailable for % on %', v_from, p_rate_date;
    end if;
    -- fx_rate meaning: 1 foreign = fx_rate base
    v_base_amount := p_amount * v_fx_from;
  end if;

  -- Step 2: Convert from base to target
  if v_to = v_base then
    return round(v_base_amount, 4);
  end if;

  v_fx_to := public.get_fx_rate(v_to, p_rate_date, p_rate_type);
  if v_fx_to is null or v_fx_to <= 0 then
    raise exception 'FX rate unavailable for % on %', v_to, p_rate_date;
  end if;
  -- base_amount / fx_rate = foreign amount
  return round(v_base_amount / v_fx_to, 4);
end;
$$;

revoke all on function public.convert_currency(numeric, text, text, date, text) from public;
grant execute on function public.convert_currency(numeric, text, text, date, text) to authenticated;


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 7. FX RATE VALIDATION TRIGGER                                          │
-- │ Prevent storing clearly wrong FX rates                                 │
-- └─────────────────────────────────────────────────────────────────────────┘

create or replace function public.trg_validate_fx_rate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_hi boolean := false;
begin
  if new.rate is null or new.rate <= 0 then
    raise exception 'FX rate must be positive, got: %', new.rate;
  end if;

  -- Check if this is a high-inflation currency
  select coalesce(c.is_high_inflation, false)
  into v_is_hi
  from public.currencies c
  where upper(c.code) = upper(new.currency_code);

  -- After normalization, high-inflation rates should be < 1
  -- Non-high-inflation rates should be reasonable (0.001 to 10000)
  if v_is_hi and new.rate > 10 then
    raise warning 'FX rate % for high-inflation currency % seems unnormalized (expected < 1). Consider inverting.',
      new.rate, new.currency_code;
  end if;

  if not v_is_hi and (new.rate < 0.001 or new.rate > 10000) then
    raise warning 'FX rate % for currency % seems extreme. Please verify.',
      new.rate, new.currency_code;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_fx_rates_validate on public.fx_rates;
create trigger trg_fx_rates_validate
  before insert or update on public.fx_rates
  for each row execute function public.trg_validate_fx_rate();


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 8. BATCH COST VALIDATION ON INSERT/UPDATE                              │
-- │ Detect potential currency mismatch at receipt time                      │
-- └─────────────────────────────────────────────────────────────────────────┘

create or replace function public.trg_validate_batch_cost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
begin
  v_base := public.get_base_currency();

  -- If foreign_currency is set, validate consistency
  if new.foreign_currency is not null and upper(new.foreign_currency) <> upper(v_base) then

    -- If foreign_unit_cost exists, unit_cost should be much smaller (base currency)
    if new.foreign_unit_cost is not null and new.foreign_unit_cost > 0
       and new.unit_cost is not null and new.unit_cost > 0 then

      -- For high-inflation currencies, unit_cost (base) should be << foreign_unit_cost
      if new.unit_cost > new.foreign_unit_cost * 2 then
        raise warning 'Batch cost anomaly: unit_cost (%) > foreign_unit_cost (%) * 2 for foreign currency %. Possible currency mismatch.',
          new.unit_cost, new.foreign_unit_cost, new.foreign_currency;
      end if;
    end if;

    -- If fx_rate_at_receipt is 1 for a foreign currency, that's suspicious
    if new.fx_rate_at_receipt is not null and new.fx_rate_at_receipt = 1 then
      raise warning 'Batch has fx_rate_at_receipt=1 for foreign currency %. This is likely incorrect.',
        new.foreign_currency;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_batches_validate_cost on public.batches;
create trigger trg_batches_validate_cost
  before insert or update on public.batches
  for each row execute function public.trg_validate_batch_cost();


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 9. UPDATE get_fefo_pricing WITH SAFETY GUARD                           │
-- │ Add price validation before returning to POS                           │
-- └─────────────────────────────────────────────────────────────────────────┘

-- This is applied via the existing function in 20260215140000
-- We only add the guard wrapper at the final return points

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
  v_validated_price numeric;
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

  -- ═══ SAFETY GUARD: validate price reasonableness ═══
  v_validated_price := greatest(coalesce(v_price, 0), coalesce(v_min_cur, 0));
  v_validated_price := public.validate_price_reasonableness(v_validated_price, v_currency, p_item_id);
  suggested_price := v_validated_price;

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

notify pgrst, 'reload schema';
