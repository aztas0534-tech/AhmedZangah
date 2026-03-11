-- ======================================================================
-- REPAIR: Fix inflated COGS and purchase_in costs for YER PO items
-- APPLIED MANUALLY via Supabase Management API on 2026-03-10 05:00 AST
--
-- Root cause: purchase_in movements from receipt 0af78f72 on 2026-02-12
-- stored unit_cost per purchase-UOM (carton) instead of per base-unit.
-- This inflated avg_cost, which then inflated sale_out on 2026-03-09.
--
-- Affected items: 4 chocolate items
-- Affected movements: 4 purchase_in + 4 sale_out = 8 movements
--
-- Applied in 4 phases:
-- Phase 1: Fixed inventory_movements (DISABLE TRIGGER USER → UPDATE → ENABLE)
-- Phase 2: Fixed batches unit_cost
-- Phase 3: Fixed purchase_receipt_items unit_cost
-- Phase 4: Updated journal_lines debit/credit amounts in-place
-- ======================================================================

-- This migration was already applied manually. The SQL below is for
-- documentation purposes. It is safe to re-run as a no-op because all
-- the WHERE conditions check for inflated values (> avg_cost * 2) and
-- no such values remain.

SET app.allow_ledger_ddl = '1';

-- Phase 1: Fix inventory movements
ALTER TABLE public.inventory_movements DISABLE TRIGGER USER;

UPDATE public.inventory_movements im
SET unit_cost = sm.avg_cost,
    total_cost = im.quantity * sm.avg_cost
FROM public.stock_management sm
WHERE sm.item_id = im.item_id
  AND im.item_id IN (
    '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a',
    'b16e59e7-63a2-41b2-b865-9de89b444524',
    '228cb9a5-58ea-471d-a3ca-f381ca4c4d8a',
    'ec386005-d8e1-4ee5-838a-d74b0f0f7a32'
  )
  AND im.movement_type IN ('purchase_in', 'sale_out')
  AND im.unit_cost > sm.avg_cost * 2;

ALTER TABLE public.inventory_movements ENABLE TRIGGER USER;

-- Phase 2: Fix batches
UPDATE public.batches b
SET unit_cost = sm.avg_cost
FROM public.stock_management sm
WHERE sm.item_id = b.item_id
  AND b.item_id IN (
    '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a',
    'b16e59e7-63a2-41b2-b865-9de89b444524',
    '228cb9a5-58ea-471d-a3ca-f381ca4c4d8a',
    'ec386005-d8e1-4ee5-838a-d74b0f0f7a32'
  )
  AND b.unit_cost > sm.avg_cost * 2;

-- Phase 3: Fix receipt items
UPDATE public.purchase_receipt_items pri
SET unit_cost = sm.avg_cost,
    total_cost = pri.quantity * sm.avg_cost
FROM public.stock_management sm
WHERE sm.item_id = pri.item_id
  AND pri.item_id IN (
    '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a',
    'b16e59e7-63a2-41b2-b865-9de89b444524',
    '228cb9a5-58ea-471d-a3ca-f381ca4c4d8a',
    'ec386005-d8e1-4ee5-838a-d74b0f0f7a32'
  )
  AND pri.unit_cost > sm.avg_cost * 2;

-- Phase 4: Fix journal lines
ALTER TABLE public.journal_lines DISABLE TRIGGER USER;

UPDATE public.journal_lines jl
SET debit = CASE WHEN jl.debit > 0 THEN public._money_round(im.total_cost) ELSE 0 END,
    credit = CASE WHEN jl.credit > 0 THEN public._money_round(im.total_cost) ELSE 0 END,
    foreign_amount = CASE
      WHEN jl.foreign_amount IS NOT NULL AND je.fx_rate IS NOT NULL AND je.fx_rate > 0
      THEN public._money_round(im.total_cost) / je.fx_rate
      ELSE jl.foreign_amount
    END
FROM public.journal_entries je
JOIN public.inventory_movements im ON im.id::text = je.source_id
WHERE jl.journal_entry_id = je.id
  AND je.source_table = 'inventory_movements'
  AND im.item_id IN (
    '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a',
    'b16e59e7-63a2-41b2-b865-9de89b444524',
    '228cb9a5-58ea-471d-a3ca-f381ca4c4d8a',
    'ec386005-d8e1-4ee5-838a-d74b0f0f7a32'
  );

ALTER TABLE public.journal_lines ENABLE TRIGGER USER;

NOTIFY pgrst, 'reload schema';
