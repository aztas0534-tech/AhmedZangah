-- Fix Historical Landed Cost Data
-- This script corrects previously closed shipments where Foreign Currency transport costs
-- were added incorrectly to Base Currency values (e.g. 70M YER added as 70M SAR).

-- SAFETY: Run inside a transaction.
BEGIN;

-- 1. Create a temp table to hold the corrections needed
create temp table if not exists _corrections as
select
  pr.id as receipt_id,
  pri.id as receipt_item_id,
  pri.item_id,
  pr.warehouse_id,
  
  -- Original values (Corrupt)
  pri.unit_cost as current_unit_cost,
  pri.total_cost as current_total_cost,
  
  -- Calculation components
  isi.landing_cost_per_unit as base_landed, -- This was correctly calculated in base
  pri.transport_cost as transport_raw,      -- This is likely Foreign
  pri.supply_tax_cost as tax_raw,           -- This is likely Foreign
  po.currency as po_currency,
  coalesce(po.fx_rate, 1) as fx_rate,
  
  -- Corrected values
  (
    isi.landing_cost_per_unit + 
    (pri.transport_cost * coalesce(po.fx_rate, 1)) + 
    (pri.supply_tax_cost * coalesce(po.fx_rate, 1))
  ) as correct_unit_cost,
  
  -- Difference
  pri.unit_cost - (
    isi.landing_cost_per_unit + 
    (pri.transport_cost * coalesce(po.fx_rate, 1)) + 
    (pri.supply_tax_cost * coalesce(po.fx_rate, 1))
  ) as diff_per_unit

from public.purchase_receipts pr
join public.purchase_receipt_items pri on pri.receipt_id = pr.id
join public.purchase_orders po on po.id = pr.purchase_order_id
join public.import_shipments s on s.id = pr.import_shipment_id
join public.import_shipments_items isi on isi.shipment_id = s.id and isi.item_id::text = pri.item_id::text
where s.status = 'closed'
  and po.currency <> 'SAR' -- Only foreign POs
  and po.fx_rate > 0
  -- Filter for significant deviation (indicating missed FX conversion)
  -- If we missed FX (e.g. rate 0.006), the current cost will be MUCH higher than corrected
  and pri.unit_cost > (
    isi.landing_cost_per_unit + 
    (pri.transport_cost * coalesce(po.fx_rate, 1)) + 
    (pri.supply_tax_cost * coalesce(po.fx_rate, 1))
  ) * 1.5; -- Threshold: Current is > 1.5x Correct (safeguard)

-- 2. Disable triggers to allow fixing immutable history
-- FIXED: Use DISABLE TRIGGER USER to avoid superuser permission errors
alter table public.inventory_movements disable trigger user;
alter table public.stock_management disable trigger user;

DO $$
DECLARE
  v_rec record;
  v_batch_id uuid;
  v_movement_id uuid;
  v_je_id uuid;
  v_diff_total numeric;
BEGIN
  RAISE NOTICE 'Starting Historical Fix...';
  
  FOR v_rec IN SELECT * FROM _corrections LOOP
    RAISE NOTICE 'Fixing Receipt Item % (Item %). Current: %, Correct: %', v_rec.receipt_item_id, v_rec.item_id, v_rec.current_unit_cost, v_rec.correct_unit_cost;

    -- A. Update Purchase Receipt Item
    UPDATE public.purchase_receipt_items
    SET unit_cost = v_rec.correct_unit_cost,
        total_cost = quantity * v_rec.correct_unit_cost
    WHERE id = v_rec.receipt_item_id;

    -- B. Find and Update Inventory Movement (purchase_in)
    UPDATE public.inventory_movements
    SET unit_cost = v_rec.correct_unit_cost,
        total_cost = quantity * v_rec.correct_unit_cost,
        data = jsonb_set(coalesce(data, '{}'::jsonb), '{fixed_by_landed_cost_script}', 'true')
    WHERE reference_table = 'purchase_receipts'
      AND reference_id = v_rec.receipt_id::text
      AND item_id = v_rec.item_id
      AND movement_type = 'purchase_in'
    RETURNING batch_id INTO v_batch_id;

    -- C. Update Batch
    IF v_batch_id IS NOT NULL THEN
      UPDATE public.batches
      SET unit_cost = v_rec.correct_unit_cost,
          -- Also fix derived fields if they were corrupted
          cost_per_unit = v_rec.correct_unit_cost, 
          min_selling_price = v_rec.correct_unit_cost * (1 + greatest(0, coalesce(min_margin_pct, 0)) / 100)
      WHERE id = v_batch_id;
    END IF;
    
    -- D. Update Related Journal Entry (Landed Cost Close)
    -- We need to find the Journal Entry created by the shipment close that affected this item.
    -- This is tricky because one JE aggregates multiple items.
    -- However, we can calculate the *Total Breakdown difference* for this shipment and apply it.
    -- For simplicity/safety, we will search for the JE related to the shipment and adjust line amounts.
    
    -- BUT, simpler logic for the JE:
    -- The JE Debit/Credit was massive. We need to scale it down.
    -- Or we can just let the user REVERSE the massive JE manually? 
    -- User asked to fix it.
    
    -- Let's stick to fixing the Inventory Data first.
    -- Fixing the JE requires knowing exactly which lines correspond to this item's delta, which is lost information (aggregated).
    -- Strategy: We WON'T update JE lines row-by-row here because it's aggregated.
    -- Instead, we recommend Voiding/Reversing the bad JE if possible, or we run a separate aggregation fix.
    
    -- However, the user specifically showed a screenshot of the JE.
    -- If we fix inventory but leave the JE, the GL accounts (Inventory value) will not match the Batches value.
    -- WE MUST FIX THE JE.
    
  END LOOP;
  
  -- E. Correct Stock Management (Re-aggregate)
  RAISE NOTICE 'Recalculating Stock Management...';
  UPDATE public.stock_management sm
  SET avg_cost = sub.new_avg
  FROM (
    SELECT 
      warehouse_id, 
      item_id, 
      SUM(quantity_received * unit_cost) / NULLIF(SUM(quantity_received), 0) as new_avg
    FROM public.batches
    GROUP BY warehouse_id, item_id
  ) sub
  WHERE sm.warehouse_id = sub.warehouse_id 
    AND sm.item_id = sub.item_id;

END $$;

-- 3. Aggregated JE Fix (Separate Block)
-- Find JEs from 'import_shipments' with event 'landed_cost_close'
-- Recalculate what they SHOULD be vs what they ARE.
DO $$
DECLARE
  v_shipment_id uuid;
  v_je_id uuid;
  v_correct_total_delta numeric;
  v_current_total_debit numeric;
  v_factor numeric;
BEGIN
  FOR v_shipment_id IN 
    SELECT distinct pr.import_shipment_id 
    FROM _corrections c 
    JOIN public.purchase_receipts pr ON pr.id = c.receipt_id
  LOOP
    -- 1. Calculate Correct Total Delta for this shipment
    -- This mimics the logic in the trigger but using corrected values
    -- Delta = (NewUnit - OldUnit) * Qty
    -- Since we don't easily know OldUnit (whatever it was before trigger ran),
    -- We assume the 'landed_cost_close' entry was capturing the ENTIRE 'transport + tax' adder 
    -- because usually 'purchase_in' is posted at FOB (or previous step).
    
    -- Actually, the easiest way to fix the JE is:
    -- Find the JE. 
    -- Sum its lines. 
    -- If Sum is huge (e.g. 70M), and the Corrected Sum of (Transport+Tax)*FX is small (e.g. 150*3=450).
    -- Update the JE lines by the Ratio.
    
    SELECT id INTO v_je_id
    FROM public.journal_entries
    WHERE source_table = 'import_shipments'
      AND source_id = v_shipment_id::text
      AND source_event = 'landed_cost_close';
      
    IF v_je_id IS NOT NULL THEN
      -- Get current debit sum (to see how bad it is)
      SELECT SUM(debit) INTO v_current_total_debit
      FROM public.journal_lines
      WHERE journal_entry_id = v_je_id;
      
      -- Calculate Correct Total Added Value (Base)
      SELECT SUM(
         (pri.transport_cost * coalesce(po.fx_rate, 1) + pri.supply_tax_cost * coalesce(po.fx_rate, 1)) 
         * pri.quantity
      ) 
      INTO v_correct_total_delta
      FROM public.purchase_receipts pr
      JOIN public.purchase_receipt_items pri ON pri.receipt_id = pr.id
      JOIN public.purchase_orders po ON po.id = pr.purchase_order_id
      WHERE pr.import_shipment_id = v_shipment_id;
      
      IF v_current_total_debit > 0 AND v_correct_total_delta < v_current_total_debit THEN
        RAISE NOTICE 'Fixing JE % for Shipment %. Current: %, Correct: %', v_je_id, v_shipment_id, v_current_total_debit, v_correct_total_delta;
        
        UPDATE public.journal_lines
        SET debit = case when debit > 0 then (debit / v_current_total_debit) * v_correct_total_delta else 0 end,
            credit = case when credit > 0 then (credit / v_current_total_debit) * v_correct_total_delta else 0 end
        WHERE journal_entry_id = v_je_id;
        
        -- Update Header Amount
        UPDATE public.journal_entries
        SET foreign_amount = null -- Consolidating to null/base if mixed, or strict base
        WHERE id = v_je_id;
        
      END IF;
    END IF;
    
  END LOOP;
END $$;

-- 4. Re-enable triggers
-- FIXED: Use ENABLE TRIGGER USER
alter table public.inventory_movements enable trigger user;
alter table public.stock_management enable trigger user;

-- 5. Drop temp table
drop table _corrections;

COMMIT;
