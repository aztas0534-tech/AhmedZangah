-- Fix Historical Purchase Receipt Journals (Foreign Currency Mix)
-- This script corrects "Purchase In" movements and journals where Foreign Currency was used as Base.

BEGIN;

create temp table _pr_corrections as
select
  pr.id as receipt_id,
  pri.id as receipt_item_id,
  pri.item_id,
  pr.warehouse_id,
  
  -- Current (Wrong)
  pri.unit_cost as current_unit_cost,
  
  -- Components
  po.currency,
  coalesce(po.fx_rate, 1) as fx_rate,
  
  -- Adders (Foreign)
  pri.transport_cost as transport_val,
  pri.supply_tax_cost as tax_val,

  -- Corrected Base
  (
    coalesce(pi.unit_cost_base, pi.unit_cost * coalesce(po.fx_rate, 1)) +
    (coalesce(pri.transport_cost, 0) * coalesce(po.fx_rate, 1)) +
    (coalesce(pri.supply_tax_cost, 0) * coalesce(po.fx_rate, 1))
  ) as correct_unit_cost

from public.purchase_receipts pr
join public.purchase_receipt_items pri on pri.receipt_id = pr.id
join public.purchase_items pi on pi.purchase_order_id = pr.purchase_order_id and pi.item_id = pri.item_id
join public.purchase_orders po on po.id = pr.purchase_order_id
where po.currency <> 'SAR'
  and coalesce(po.fx_rate, 1) > 0
  -- Detection logic: Current Cost is significantly higher than Corrected Cost
  and pri.unit_cost > (
    coalesce(pi.unit_cost_base, pi.unit_cost * coalesce(po.fx_rate, 1)) +
    (coalesce(pri.transport_cost, 0) * coalesce(po.fx_rate, 1)) +
    (coalesce(pri.supply_tax_cost, 0) * coalesce(po.fx_rate, 1))
  ) * 1.5;

-- Disable triggers
-- FIXED: Use DISABLE TRIGGER USER
alter table public.inventory_movements disable trigger user;
alter table public.stock_management disable trigger user;

DO $$
DECLARE
  v_rec record;
  v_batch_id uuid;
  v_movement_id uuid; -- Captured ID
  v_je_id uuid;
  v_correct_total numeric;
  v_current_total numeric;
BEGIN
  FOR v_rec IN SELECT * FROM _pr_corrections LOOP
    RAISE NOTICE 'Fixing Receipt % Item %. Current: %, Correct: %', v_rec.receipt_id, v_rec.item_id, v_rec.current_unit_cost, v_rec.correct_unit_cost;
    
    -- 1. Update Receipt Item
    UPDATE public.purchase_receipt_items
    SET unit_cost = v_rec.correct_unit_cost,
        total_cost = quantity * v_rec.correct_unit_cost,
        transport_cost = coalesce(transport_cost, 0) * v_rec.fx_rate, 
        supply_tax_cost = coalesce(supply_tax_cost, 0) * v_rec.fx_rate
    WHERE id = v_rec.receipt_item_id;
    
    -- 2. Update Movement
    UPDATE public.inventory_movements
    SET unit_cost = v_rec.correct_unit_cost,
        total_cost = quantity * v_rec.correct_unit_cost,
        data = jsonb_set(coalesce(data, '{}'::jsonb), '{fixed_by_pr_script}', 'true')
    WHERE reference_table = 'purchase_receipts'
      AND reference_id = v_rec.receipt_id::text
      AND item_id = v_rec.item_id
      AND movement_type = 'purchase_in'
    RETURNING batch_id, id INTO v_batch_id, v_movement_id; -- Capture movement ID
    
    -- 3. Update Batch
    IF v_batch_id IS NOT NULL THEN
      UPDATE public.batches
      SET unit_cost = v_rec.correct_unit_cost,
          cost_per_unit = v_rec.correct_unit_cost
      WHERE id = v_batch_id;
    END IF;

    -- 4. FIX JOURNAL ENTRY (Linked to THIS Movement)
    IF v_movement_id IS NOT NULL THEN
       -- Find JE sourced from THIS inventory movement
       v_je_id := null;
       SELECT id INTO v_je_id 
       FROM public.journal_entries 
       WHERE source_table = 'inventory_movements' 
         AND source_id = v_movement_id::text;
         
       IF v_je_id IS NOT NULL THEN
          -- Calculate Correct Total for this Item Line
          SELECT (quantity * v_rec.correct_unit_cost) INTO v_correct_total
          FROM public.inventory_movements
          WHERE id = v_movement_id;
          
          -- Calculate Current Debit Sum for this JE
          SELECT sum(debit) INTO v_current_total
          FROM public.journal_lines
          WHERE journal_entry_id = v_je_id;
          
          IF v_current_total > 0 AND abs(v_current_total - v_correct_total) > 1.0 THEN
             RAISE NOTICE 'Fixing JE % for Movement %. Current: %, Correct: %', v_je_id, v_movement_id, v_current_total, v_correct_total;
             
             UPDATE public.journal_lines
             SET debit = case when debit > 0 then (debit / v_current_total) * v_correct_total else 0 end,
                 credit = case when credit > 0 then (credit / v_current_total) * v_correct_total else 0 end
             WHERE journal_entry_id = v_je_id;
             
             -- Also fix Header
             UPDATE public.journal_entries
             SET foreign_amount = null
             WHERE id = v_je_id;
          END IF;
       END IF;
    END IF;

  END LOOP;
  
  -- 5. Fix Journal Entries (Legacy: Sourced from purchase_receipts directly)
  -- Some older entries might be linked directly to receipt
  FOR v_rec IN 
    SELECT distinct receipt_id FROM _pr_corrections
  LOOP
    -- Get JE
    SELECT id INTO v_je_id 
    FROM public.journal_entries 
    WHERE source_table = 'purchase_receipts' 
      AND source_id = v_rec.receipt_id::text;
    
    IF v_je_id IS NOT NULL THEN
       -- Calculate Correct Total for Receipt
       SELECT sum(total_cost) INTO v_correct_total
       FROM public.purchase_receipt_items
       WHERE receipt_id = v_rec.receipt_id;
       
       -- Calculate Current Debit
       SELECT sum(debit) INTO v_current_total
       FROM public.journal_lines
       WHERE journal_entry_id = v_je_id;
       
       IF v_current_total > 0 AND v_correct_total < v_current_total THEN
          RAISE NOTICE 'Fixing Legacy JE % for Receipt %. Current: %, Correct: %', v_je_id, v_rec.receipt_id, v_current_total, v_correct_total;
          
          UPDATE public.journal_lines
          SET debit = case when debit > 0 then (debit / v_current_total) * v_correct_total else 0 end,
              credit = case when credit > 0 then (credit / v_current_total) * v_correct_total else 0 end
          WHERE journal_entry_id = v_je_id;
       END IF;
    END IF;
  END LOOP;
  
  -- 6. Recalculate Stock
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

-- Enable triggers
-- FIXED: Use ENABLE TRIGGER USER
alter table public.inventory_movements enable trigger user;
alter table public.stock_management enable trigger user;

drop table _pr_corrections;

COMMIT;
