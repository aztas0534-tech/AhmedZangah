create or replace function public.diag_get_stuck_po_returns()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  res jsonb;
begin
  select jsonb_agg(
    jsonb_build_object(
      'return_id', pr.id,
      'order_id', pr.purchase_order_id,
      'item_id', pri.item_id,
      'expected_qty', pri.quantity,
      'expected_cost', pri.total_cost,
      'movement_qty', im.quantity,
      'movement_cost', im.total_cost,
      'journal_id', je.id
    )
  )
  into res
  from public.purchase_returns pr
  join public.purchase_return_items pri on pri.return_id = pr.id
  left join public.inventory_movements im on im.reference_table = 'purchase_returns' and im.reference_id = pr.id::text and im.item_id::text = pri.item_id::text
  left join public.journal_entries je on je.source_table = 'inventory_movements' and je.source_id = im.id::text;
     
  return coalesce(res, '[]'::jsonb);
end;
$$;
