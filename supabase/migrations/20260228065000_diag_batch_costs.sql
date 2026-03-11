create or replace function public.diag_analyze_batch_costs()
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
      'batch_id', b.id,
      'batch_cost', b.unit_cost,
      'batch_qty', b.quantity_received,
      'receipt_id', pr.id,
      'receipt_cost', pri.unit_cost,
      'receipt_qty', pri.quantity,
      'order_id', po.id,
      'order_cost', pi.unit_cost,
      'order_qty', pi.quantity,
      'order_currency', po.currency,
      'order_fx_rate', po.fx_rate,
      'menu_item_cost', mi.cost_price,
      'menu_item_buying', mi.buying_price,
      'menu_item_transport', mi.transport_cost,
      'menu_item_tax', mi.supply_tax_cost
    )
  )
  into res
  from public.batches b
  left join public.purchase_receipts pr on b.receipt_id = pr.id
  left join public.purchase_orders po on pr.purchase_order_id = po.id
  left join public.purchase_receipt_items pri on pri.receipt_id = pr.id and pri.item_id::text = b.item_id::text
  left join public.purchase_items pi on pi.purchase_order_id = po.id and pi.item_id::text = b.item_id::text
  left join public.menu_items mi on mi.id::text = b.item_id::text
  where b.id in (
    'ca20926d-9e9c-442a-8662-926e7232d50d',
    '793cae3c-1057-48b5-a36b-af21a9f33dc4',
    '1b80d124-6813-4f6c-b6a7-143fd836addf'
  );
     
  return coalesce(res, '[]'::jsonb);
end;
$$;

revoke all on function public.diag_analyze_batch_costs() from public;
grant execute on function public.diag_analyze_batch_costs() to anon, authenticated;

notify pgrst, 'reload schema';
