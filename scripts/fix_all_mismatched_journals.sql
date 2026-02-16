-- Fix ALL Mismatched Journal Entries
-- Covers: inventory_movements, import_shipments (landed_cost_close), purchase_receipts
-- Strategy: For each JE, recalculate the correct amount from the source data and fix the lines.

set app.allow_ledger_ddl = '1';

BEGIN;

-- Disable Safety Triggers
alter table public.journal_lines disable trigger user;
alter table public.journal_entries disable trigger user;

-- ============================================================
-- PART 1: Fix JEs sourced from inventory_movements
-- ============================================================
DO $$
DECLARE
  v_rec record;
BEGIN
  RAISE NOTICE '=== PART 1: Fixing inventory_movements JEs ===';
  FOR v_rec IN
    SELECT
      je.id as je_id,
      je.source_id as movement_id,
      im.total_cost as correct_amount,
      (SELECT sum(debit) FROM public.journal_lines WHERE journal_entry_id = je.id) as current_amount
    FROM public.journal_entries je
    JOIN public.inventory_movements im ON im.id::text = je.source_id
    WHERE je.source_table = 'inventory_movements'
      AND abs((SELECT sum(debit) FROM public.journal_lines WHERE journal_entry_id = je.id) - im.total_cost) > 1
  LOOP
    RAISE NOTICE 'Fix JE % (movement %). Current: %, Correct: %', v_rec.je_id, v_rec.movement_id, v_rec.current_amount, v_rec.correct_amount;

    UPDATE public.journal_lines
    SET debit  = CASE WHEN debit  > 0 THEN (debit  / v_rec.current_amount) * v_rec.correct_amount ELSE 0 END,
        credit = CASE WHEN credit > 0 THEN (credit / v_rec.current_amount) * v_rec.correct_amount ELSE 0 END
    WHERE journal_entry_id = v_rec.je_id;
  END LOOP;
END $$;

-- ============================================================
-- PART 2: Fix JEs sourced from import_shipments (landed_cost_close)
-- These are the 70M entries.
-- Correct amount = SUM of (transport_cost + supply_tax_cost) * FX_RATE * quantity
-- for all receipt items linked to this shipment.
-- ============================================================
DO $$
DECLARE
  v_rec record;
  v_correct_amount numeric;
BEGIN
  RAISE NOTICE '=== PART 2: Fixing import_shipments JEs ===';
  FOR v_rec IN
    SELECT
      je.id as je_id,
      je.source_id as shipment_id,
      je.source_event,
      (SELECT sum(debit) FROM public.journal_lines WHERE journal_entry_id = je.id) as current_amount
    FROM public.journal_entries je
    WHERE je.source_table = 'import_shipments'
      AND (SELECT sum(debit) FROM public.journal_lines WHERE journal_entry_id = je.id) > 100000 -- Only fix huge ones
  LOOP
    -- Calculate correct landed cost delta for this shipment
    -- The landed cost close adds (transport + tax) per unit to each item.
    -- If these were stored in Foreign Currency but should have been converted, 
    -- we need to recalculate using the PO FX rate.
    
    SELECT COALESCE(SUM(
      pri.quantity * (
        COALESCE(isi.landing_cost_per_unit, 0) -- This is the per-unit adder from the shipment item
      )
    ), 0)
    INTO v_correct_amount
    FROM public.purchase_receipts pr
    JOIN public.purchase_receipt_items pri ON pri.receipt_id = pr.id
    JOIN public.import_shipments_items isi ON isi.shipment_id::text = v_rec.shipment_id AND isi.item_id = pri.item_id
    WHERE pr.import_shipment_id::text = v_rec.shipment_id;

    -- If we couldn't calculate a correct amount from shipment items, try from the shipment directly
    IF v_correct_amount IS NULL OR v_correct_amount <= 0 THEN
      -- Fallback: Use total_cost from import_shipments_items
      SELECT COALESCE(SUM(isi.total_cost), 0)
      INTO v_correct_amount
      FROM public.import_shipments_items isi
      WHERE isi.shipment_id::text = v_rec.shipment_id;
    END IF;

    -- Safety: Only fix if the current amount is significantly larger than correct
    IF v_correct_amount > 0 AND v_rec.current_amount > v_correct_amount * 1.5 THEN
      RAISE NOTICE 'Fix Shipment JE % (shipment %). Current: %, Correct: %', v_rec.je_id, v_rec.shipment_id, v_rec.current_amount, v_correct_amount;

      UPDATE public.journal_lines
      SET debit  = CASE WHEN debit  > 0 THEN (debit  / v_rec.current_amount) * v_correct_amount ELSE 0 END,
          credit = CASE WHEN credit > 0 THEN (credit / v_rec.current_amount) * v_correct_amount ELSE 0 END
      WHERE journal_entry_id = v_rec.je_id;
    ELSE
      RAISE NOTICE 'Skipping Shipment JE % - correct amount (%) not significantly less than current (%), or zero.', v_rec.je_id, v_correct_amount, v_rec.current_amount;
    END IF;
  END LOOP;
END $$;

-- ============================================================
-- PART 3: Fix JEs sourced from purchase_receipts (if any exist)
-- ============================================================
DO $$
DECLARE
  v_rec record;
  v_correct_amount numeric;
BEGIN
  RAISE NOTICE '=== PART 3: Fixing purchase_receipts JEs ===';
  FOR v_rec IN
    SELECT
      je.id as je_id,
      je.source_id as receipt_id,
      (SELECT sum(debit) FROM public.journal_lines WHERE journal_entry_id = je.id) as current_amount
    FROM public.journal_entries je
    WHERE je.source_table = 'purchase_receipts'
      AND (SELECT sum(debit) FROM public.journal_lines WHERE journal_entry_id = je.id) > 100000
  LOOP
    -- Correct amount = SUM of total_cost from receipt items
    SELECT COALESCE(SUM(pri.total_cost), 0)
    INTO v_correct_amount
    FROM public.purchase_receipt_items pri
    WHERE pri.receipt_id::text = v_rec.receipt_id;

    IF v_correct_amount > 0 AND v_rec.current_amount > v_correct_amount * 1.5 THEN
      RAISE NOTICE 'Fix Receipt JE % (receipt %). Current: %, Correct: %', v_rec.je_id, v_rec.receipt_id, v_rec.current_amount, v_correct_amount;

      UPDATE public.journal_lines
      SET debit  = CASE WHEN debit  > 0 THEN (debit  / v_rec.current_amount) * v_correct_amount ELSE 0 END,
          credit = CASE WHEN credit > 0 THEN (credit / v_rec.current_amount) * v_correct_amount ELSE 0 END
      WHERE journal_entry_id = v_rec.je_id;
    END IF;
  END LOOP;
END $$;

-- Re-enable Triggers
alter table public.journal_lines enable trigger user;
alter table public.journal_entries enable trigger user;

COMMIT;
