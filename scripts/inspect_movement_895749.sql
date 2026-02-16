-- Inspect Inventory Movement to find root cause of 2.2M entry

select 
  im.id as movement_id,
  im.occurred_at,
  im.item_id,
  im.movement_type,
  im.quantity,
  im.unit_cost,
  im.total_cost,
  im.reference_table,
  im.reference_id,
  
  -- If Receipt, get PO details
  pr.id as receipt_id,
  po.reference_number as po_ref,
  po.currency as po_currency,
  po.fx_rate as po_fx_rate
  
from public.inventory_movements im
left join public.purchase_receipts pr on im.reference_table = 'purchase_receipts' and im.reference_id = pr.id::text
left join public.purchase_orders po on pr.purchase_order_id = po.id
where im.id = '895749eb-1b7e-4506-8fba-a8080233dbca';
