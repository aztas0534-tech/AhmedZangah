-- ═══════════════════════════════════════════════════════════════════════
-- PRODUCTION FIX: Run this in Supabase SQL Editor to fix batch costs
-- This undoes the damage from the wrong formula (/ instead of *)
-- and recalculates all cost fields correctly
-- ═══════════════════════════════════════════════════════════════════════
-- FX RATE DIRECTION after normalization:
--   get_fx_rate('YER') = ~0.00667 meaning "1 YER = 0.00667 SAR"
--   CORRECT: base_cost = foreign_cost * fx_rate  (MULTIPLY)
--   WRONG:   base_cost = foreign_cost / fx_rate  (this multiplied by 150!)
-- ═══════════════════════════════════════════════════════════════════════

do $$
declare
  v_base text;
  v_count int := 0;
begin
  v_base := public.get_base_currency();

  -- Fix ALL foreign-currency batches:
  -- Recalculate unit_cost, cost_per_unit, min_selling_price
  -- from foreign_unit_cost using CORRECT formula (multiply by fx_rate)

  update public.batches b
  set
    fx_rate_at_receipt = coalesce(
      nullif(
        public.get_fx_rate(b.foreign_currency, coalesce(b.created_at::date, current_date), 'operational'),
        0
      ),
      b.fx_rate_at_receipt
    ),
    unit_cost = round(
      b.foreign_unit_cost *
      coalesce(
        nullif(public.get_fx_rate(b.foreign_currency, coalesce(b.created_at::date, current_date), 'operational'), 0),
        b.fx_rate_at_receipt
      ),
      4
    ),
    cost_per_unit = round(
      b.foreign_unit_cost *
      coalesce(
        nullif(public.get_fx_rate(b.foreign_currency, coalesce(b.created_at::date, current_date), 'operational'), 0),
        b.fx_rate_at_receipt
      ),
      4
    ),
    min_selling_price = round(
      b.foreign_unit_cost *
      coalesce(
        nullif(public.get_fx_rate(b.foreign_currency, coalesce(b.created_at::date, current_date), 'operational'), 0),
        b.fx_rate_at_receipt
      ) *
      (1 + greatest(0, coalesce(b.min_margin_pct, 0)) / 100),
      4
    )
  where b.foreign_currency is not null
    and upper(b.foreign_currency) <> upper(v_base)
    and coalesce(b.foreign_unit_cost, 0) > 0;

  get diagnostics v_count = row_count;
  raise notice 'Fixed % foreign-currency batches. All costs recalculated with MULTIPLY formula.', v_count;

  -- Also fix batches that have NO foreign data but came from foreign POs
  with po_batches as (
    select
      b.id as batch_id,
      upper(po.currency) as po_currency,
      coalesce(
        nullif(po.fx_rate, 0),
        public.get_fx_rate(po.currency, coalesce(b.created_at::date, current_date), 'operational')
      ) as fx,
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
  )
  update public.batches b
  set
    foreign_currency = pb.po_currency,
    foreign_unit_cost = pb.foreign_cost,
    fx_rate_at_receipt = pb.fx,
    unit_cost = round(pb.foreign_cost * pb.fx, 4),
    cost_per_unit = round(pb.foreign_cost * pb.fx, 4),
    min_selling_price = round(
      pb.foreign_cost * pb.fx
      * (1 + greatest(0, coalesce(pb.min_margin_pct, 0)) / 100),
      4
    )
  from po_batches pb
  where b.id = pb.batch_id
    and pb.fx is not null
    and pb.fx > 0;

  get diagnostics v_count = row_count;
  raise notice 'Fixed % batches with missing foreign data. Done.', v_count;
end $$;
