-- ═══════════════════════════════════════════════════════════════════════════
-- Auto-register FOREIGN_COST_PLUS_MARGIN for items with foreign batches
-- ═══════════════════════════════════════════════════════════════════════════
-- This migration:
-- 1. Automatically creates product_prices_multi_currency entries
--    for all items that have batches purchased in foreign currency
-- 2. Uses FOREIGN_COST_PLUS_MARGIN method so prices are locked
--    at the batch's receipt-time FX rate
-- 3. Also registers a SAR pricing rule (BASE_PLUS_MARGIN) so sales
--    in SAR use the locked batch cost, not live FX
-- 4. Adds a trigger on batches to auto-register when new foreign
--    items are received
-- ═══════════════════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 1. BACKFILL: Register FOREIGN_COST_PLUS_MARGIN for existing items      │
-- └─────────────────────────────────────────────────────────────────────────┘

do $$
declare
  v_base text;
  v_count_foreign int := 0;
  v_count_base int := 0;
  v_default_margin numeric := 15;  -- 15% default margin
begin
  v_base := public.get_base_currency();

  -- For each item that has foreign-currency batches,
  -- create a FOREIGN_COST_PLUS_MARGIN pricing rule in the batch's currency
  insert into public.product_prices_multi_currency(
    item_id,
    currency_code,
    pricing_method,
    price_value,
    margin_percent,
    fx_source,
    is_active,
    effective_from
  )
  select distinct
    b.item_id,
    upper(b.foreign_currency),
    'FOREIGN_COST_PLUS_MARGIN'::public.pricing_method_enum,
    null::numeric,  -- no fixed price, uses batch cost + margin
    v_default_margin,
    'PURCHASE_SNAPSHOT'::public.pricing_fx_source_enum,
    true,
    current_date
  from public.batches b
  where b.foreign_currency is not null
    and upper(b.foreign_currency) <> upper(v_base)
    and coalesce(b.foreign_unit_cost, 0) > 0
    -- Don't create if one already exists for this item+currency
    and not exists (
      select 1
      from public.product_prices_multi_currency ppmc
      where ppmc.item_id = b.item_id
        and upper(ppmc.currency_code) = upper(b.foreign_currency)
        and ppmc.is_active = true
    )
  group by b.item_id, upper(b.foreign_currency);

  get diagnostics v_count_foreign = row_count;

  -- Also create BASE_PLUS_MARGIN for the base currency (SAR)
  -- so SAR sales use batch cost_per_unit (locked at receipt) + margin
  insert into public.product_prices_multi_currency(
    item_id,
    currency_code,
    pricing_method,
    price_value,
    margin_percent,
    fx_source,
    is_active,
    effective_from
  )
  select distinct
    b.item_id,
    upper(v_base),
    'BASE_PLUS_MARGIN'::public.pricing_method_enum,
    null::numeric,
    v_default_margin,
    'NONE'::public.pricing_fx_source_enum,
    true,
    current_date
  from public.batches b
  where b.foreign_currency is not null
    and upper(b.foreign_currency) <> upper(v_base)
    and coalesce(b.foreign_unit_cost, 0) > 0
    and not exists (
      select 1
      from public.product_prices_multi_currency ppmc
      where ppmc.item_id = b.item_id
        and upper(ppmc.currency_code) = upper(v_base)
        and ppmc.is_active = true
    )
  group by b.item_id;

  get diagnostics v_count_base = row_count;

  raise notice 'Registered % FOREIGN_COST_PLUS_MARGIN (YER) + % BASE_PLUS_MARGIN (SAR) pricing rules.',
    v_count_foreign, v_count_base;
end $$;


-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 2. AUTO-REGISTER TRIGGER: When a new foreign batch is received         │
-- └─────────────────────────────────────────────────────────────────────────┘

create or replace function public.trg_auto_register_foreign_pricing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
  v_default_margin numeric := 15;
begin
  -- Only act on INSERT of batches with foreign currency
  if new.foreign_currency is null then
    return new;
  end if;

  v_base := public.get_base_currency();

  if upper(new.foreign_currency) = upper(v_base) then
    return new;
  end if;

  -- Auto-register FOREIGN_COST_PLUS_MARGIN if not exists
  if not exists (
    select 1
    from public.product_prices_multi_currency ppmc
    where ppmc.item_id = new.item_id
      and upper(ppmc.currency_code) = upper(new.foreign_currency)
      and ppmc.is_active = true
  ) then
    insert into public.product_prices_multi_currency(
      item_id, currency_code, pricing_method, price_value,
      margin_percent, fx_source, is_active, effective_from
    ) values (
      new.item_id,
      upper(new.foreign_currency),
      'FOREIGN_COST_PLUS_MARGIN',
      null,
      v_default_margin,
      'PURCHASE_SNAPSHOT',
      true,
      current_date
    );
  end if;

  -- Auto-register BASE_PLUS_MARGIN for SAR if not exists
  if not exists (
    select 1
    from public.product_prices_multi_currency ppmc
    where ppmc.item_id = new.item_id
      and upper(ppmc.currency_code) = upper(v_base)
      and ppmc.is_active = true
  ) then
    insert into public.product_prices_multi_currency(
      item_id, currency_code, pricing_method, price_value,
      margin_percent, fx_source, is_active, effective_from
    ) values (
      new.item_id,
      upper(v_base),
      'BASE_PLUS_MARGIN',
      null,
      v_default_margin,
      'NONE',
      true,
      current_date
    );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_batches_auto_foreign_pricing on public.batches;
create trigger trg_batches_auto_foreign_pricing
  after insert on public.batches
  for each row execute function public.trg_auto_register_foreign_pricing();


notify pgrst, 'reload schema';
