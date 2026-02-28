create or replace function public.diag_analyze_specific_pos(po_numbers text[])
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
      'po_number', po.po_number,
      'po_id', po.id,
      'status', po.status,
      'currency', po.currency,
      'fx_rate', po.fx_rate,
      'returns', (
        select jsonb_agg(
          jsonb_build_object(
            'return_id', pr.id,
            'returned_at', pr.returned_at,
            'items', (
               select jsonb_agg(
                 jsonb_build_object(
                   'item_id', pri.item_id,
                   'qty_returned', pri.quantity,
                   'total_cost', pri.total_cost,
                   'has_movement', exists(
                      select 1 from public.inventory_movements im 
                      where im.reference_table = 'purchase_returns' 
                        and im.reference_id = pr.id::text 
                        and im.item_id::text = pri.item_id::text
                        and im.quantity = pri.quantity
                   ),
                   'has_journal', exists(
                      select 1 
                      from public.inventory_movements im 
                      join public.journal_entries je on je.source_table = 'inventory_movements' and je.source_id = im.id::text
                      where im.reference_table = 'purchase_returns' 
                        and im.reference_id = pr.id::text 
                        and im.item_id::text = pri.item_id::text
                   )
                 )
               )
               from public.purchase_return_items pri
               where pri.return_id = pr.id
            )
          )
        )
        from public.purchase_returns pr
        where pr.purchase_order_id = po.id
      )
    )
  )
  into res
  from public.purchase_orders po
  where po.po_number = any(po_numbers);
     
  return coalesce(res, '[]'::jsonb);
end;
$$;

revoke all on function public.diag_analyze_specific_pos(text[]) from public;
grant execute on function public.diag_analyze_specific_pos(text[]) to anon, authenticated;

notify pgrst, 'reload schema';
