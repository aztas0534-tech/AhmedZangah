-- Audit script to find batches with 0 cost but valid PO unit cost
-- Run this in Supabase SQL Editor

WITH zero_cost_batches AS (
    SELECT 
        b.id AS batch_id,
        b.item_id,
        b.sk_id AS stock_id,
        b.cost_price,
        b.quantity,
        b.created_at,
        pi.unit_cost AS po_unit_cost,
        pi.quantity AS po_qty,
        po.currency,
        po.fx_rate,
        po.reference_number
    FROM batches b
    JOIN purchase_invoices_items pii ON pii.id::text = b.reference_id AND b.reference_table = 'purchase_invoices_items' 
    -- Note: reference_table for PO receipt might be 'purchase_receipt_items' or similar in newer logic,
    -- but usually it links via inventory_movements. 
    -- Let's try linking via inventory_movements for better accuracy.
    RIGHT JOIN inventory_movements im ON im.batch_id = b.id
    JOIN purchase_items pi ON pi.id::text = im.reference_id AND im.reference_table = 'purchase_items' -- Check specific ref logic
    JOIN purchase_orders po ON po.id = pi.purchase_order_id
    WHERE b.cost_price = 0 
      AND pi.unit_cost > 0
)
SELECT * FROM zero_cost_batches;

-- Improved Query using purchase_receipts linkage if available
-- In the current system, receivePurchaseOrderPartial creates:
-- 1. purchase_receipts (header)
-- 2. purchase_receipt_items (lines) -> This might not exist? 
--    Let's check _receive_purchase_order_partial_impl again.
--    It inserts into inventory_movements directly?
--    Line 534: insert into public.inventory_movements(..., reference_table, reference_id, ...)
--    reference_table = 'purchase_orders' (Wait, let's check the code)

/*
  From _receive_purchase_order_partial_impl:
  insert into public.inventory_movements(
    ...,
    reference_table = 'purchase_orders',
    reference_id = v_order_id, 
    ...
  )
  Actually it uses 'purchase_orders' as ref table? 
  Let's check lines 482 (batches insert).
*/
