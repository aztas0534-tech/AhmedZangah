-- Check Top 10 Most Expensive Purchase Receipts
-- Use this to see WHY the fix script is skipping them (e.g. is FX Rate = 1?)

select
  pr.id as receipt_id,
  pr.created_at,
  po.reference_number as po_ref,
  po.currency as po_currency,
  po.fx_rate as po_fx_rate, -- CRITICAL: Is this 1.0?

  
  pri.unit_cost as item_unit_cost,
  pri.total_cost as item_total_cost,
  
  -- Breakdown
  pri.transport_cost,
  pri.supply_tax_cost,
  
  -- Item Name
  mi.name as item_name
  
from public.purchase_receipts pr
join public.purchase_receipt_items pri on pri.receipt_id = pr.id
join public.purchase_orders po on po.id = pr.purchase_order_id
join public.menu_items mi on mi.id = pri.item_id
order by pri.total_cost desc
limit 10;
