-- Fix: Recalculate ALL cost fields for Foreign Currency batches where FX Rate was incorrectly stored
-- This corrects the "53,000 SAR" price issue for items received in YER/Foreign currency without conversion
-- Fixes: unit_cost, cost_per_unit, min_selling_price (all three are used by get_fefo_pricing)
--
-- FX RATE DIRECTION: get_fx_rate('YER') returns ~0.00667 meaning "1 YER = 0.00667 SAR"
-- So to convert: base_cost = foreign_cost * fx_rate (MULTIPLY, NOT DIVIDE)

do $$
declare
  v_base text;
  v_count_pass1 int := 0;
  v_count_pass2 int := 0;
  v_count_pass3 int := 0;
begin
  v_base := public.get_base_currency();

  -- ═══════════════════════════════════════════════════════════════
  -- PASS 1: Batches that HAVE foreign_unit_cost populated
  -- Detect: fx_rate_at_receipt = 1 AND unit_cost ≈ foreign_unit_cost (no conversion happened)
  -- ═══════════════════════════════════════════════════════════════

  with corrections as (
    select
      b.id,
      b.foreign_currency,
      b.foreign_unit_cost,
      b.min_margin_pct,
      public.get_fx_rate(b.foreign_currency, coalesce(b.created_at::date, current_date), 'operational') as correct_rate
    from public.batches b
    where b.foreign_currency is not null
      and upper(b.foreign_currency) <> upper(v_base)
      and coalesce(b.fx_rate_at_receipt, 1) = 1
      and coalesce(b.foreign_unit_cost, 0) > 0
      and abs(coalesce(b.unit_cost, 0) - coalesce(b.foreign_unit_cost, 0)) < 1
  )
  update public.batches b
  set
    fx_rate_at_receipt = c.correct_rate,
    -- MULTIPLY by fx_rate: 53700 YER * 0.00667 = 358 SAR
    unit_cost = case
      when c.correct_rate is not null and c.correct_rate > 0
      then round(c.foreign_unit_cost * c.correct_rate, 4)
      else b.unit_cost
    end,
    cost_per_unit = case
      when c.correct_rate is not null and c.correct_rate > 0
      then round(c.foreign_unit_cost * c.correct_rate, 4)
      else b.cost_per_unit
    end,
    min_selling_price = case
      when c.correct_rate is not null and c.correct_rate > 0
      then round(
        (c.foreign_unit_cost * c.correct_rate)
        * (1 + greatest(0, coalesce(c.min_margin_pct, 0)) / 100),
        4
      )
      else b.min_selling_price
    end
  from corrections c
  where b.id = c.id
    and c.correct_rate is not null
    and c.correct_rate > 0;

  get diagnostics v_count_pass1 = row_count;
  raise notice 'Pass 1: Fixed % batches with foreign_unit_cost but wrong fx_rate.', v_count_pass1;

  -- ═══════════════════════════════════════════════════════════════
  -- PASS 2: Batches that have NO foreign data but came from foreign-currency POs
  -- Detect: batch linked to receipt → PO with non-base currency, but batch.foreign_currency is NULL
  -- ═══════════════════════════════════════════════════════════════

  with po_batches as (
    select
      b.id as batch_id,
      upper(po.currency) as po_currency,
      coalesce(
        nullif(po.fx_rate, 0),
        public.get_fx_rate(po.currency, coalesce(b.created_at::date, current_date), 'operational')
      ) as fx,
      b.unit_cost as current_unit_cost,
      b.min_margin_pct,
      coalesce(pi.unit_cost_foreign, pi.unit_cost, b.unit_cost) as foreign_cost
    from public.batches b
    join public.purchase_receipts pr on pr.id = b.receipt_id
    join public.purchase_orders po on po.id = pr.purchase_order_id
    left join lateral (
      select pi2.unit_cost_foreign, pi2.unit_cost
      from public.purchase_items pi2
      where pi2.purchase_order_id = po.id
        and pi2.item_id = b.item_id
      order by pi2.created_at asc
      limit 1
    ) pi on true
    where b.foreign_currency is null
      and po.currency is not null
      and upper(po.currency) <> upper(v_base)
      and coalesce(b.unit_cost, 0) > 0
  )
  update public.batches b
  set
    foreign_currency = pb.po_currency,
    foreign_unit_cost = pb.foreign_cost,
    fx_rate_at_receipt = pb.fx,
    -- MULTIPLY by fx_rate: foreign * 0.00667 = base SAR
    unit_cost = case
      when pb.fx is not null and pb.fx > 0
      then round(pb.foreign_cost * pb.fx, 4)
      else b.unit_cost
    end,
    cost_per_unit = case
      when pb.fx is not null and pb.fx > 0
      then round(pb.foreign_cost * pb.fx, 4)
      else b.cost_per_unit
    end,
    min_selling_price = case
      when pb.fx is not null and pb.fx > 0
      then round(
        (pb.foreign_cost * pb.fx)
        * (1 + greatest(0, coalesce(pb.min_margin_pct, 0)) / 100),
        4
      )
      else b.min_selling_price
    end
  from po_batches pb
  where b.id = pb.batch_id
    and pb.fx is not null
    and pb.fx > 0;

  get diagnostics v_count_pass2 = row_count;
  raise notice 'Pass 2: Fixed % batches with missing foreign data from foreign POs.', v_count_pass2;

  -- ═══════════════════════════════════════════════════════════════
  -- PASS 3: Sync cost_per_unit and min_selling_price for any remaining
  -- batches where cost_per_unit is still out of sync with unit_cost
  -- This catches batches that were previously "fixed" with wrong formula
  -- ═══════════════════════════════════════════════════════════════

  update public.batches
  set
    cost_per_unit = unit_cost,
    min_selling_price = round(
      unit_cost * (1 + greatest(0, coalesce(min_margin_pct, 0)) / 100),
      4
    )
  where foreign_currency is not null
    and upper(foreign_currency) <> upper(v_base)
    and coalesce(unit_cost, 0) > 0
    and (
      abs(coalesce(cost_per_unit, 0) - coalesce(unit_cost, 0)) > 0.01
      or coalesce(cost_per_unit, 0) <= 0
    );

  get diagnostics v_count_pass3 = row_count;
  raise notice 'All passes complete. Pass1=%, Pass2=%, Pass3=%', v_count_pass1, v_count_pass2, v_count_pass3;
end $$;
