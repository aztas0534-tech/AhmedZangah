-- Find and inspect the specific 2.2M SAR transaction for Reference #444524

SELECT
  je.id as je_id,
  je.memo,
  je.entry_date,
  je.source_table,
  je.source_id,
  
  -- Sum all Debit lines (should match 2.2M)
  (select sum(debit) from public.journal_lines jl where jl.journal_entry_id = je.id) as total_debit,
  
  -- Check Related PO if exists
  case 
    when je.source_table = 'purchase_receipts' then (select reference_number from public.purchase_orders po join public.purchase_receipts pr on pr.purchase_order_id = po.id where pr.id::text = je.source_id)
    when je.source_table = 'import_shipments' then (select reference_number from public.import_shipments s where s.id::text = je.source_id)
    else null
  end as related_po_ref,
  
  -- Check Related items counts/costs
  case
    when je.source_table = 'purchase_receipts' then (select count(*) from public.purchase_receipt_items pri where pri.receipt_id::text = je.source_id)
    else null
  end as item_count
  
FROM public.journal_entries je
WHERE je.memo LIKE '%444524%'
LIMIT 5;

-- Also try to find a Receipt or PO directly with this ref
SELECT 'Purchase Order' as Type, id, reference_number, currency, fx_rate, total_amount 
FROM public.purchase_orders 
WHERE reference_number LIKE '%444524%'
UNION ALL
SELECT 'Import Shipment' as Type, id, reference_number, null, null, null 
FROM public.import_shipments 
WHERE reference_number LIKE '%444524%';
