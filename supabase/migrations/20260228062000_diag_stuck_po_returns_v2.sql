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
      'id', pr.id,
      'order_id', pr.purchase_order_id,
      'date', pr.returned_at,
      'reason', pr.reason,
      'has_movement', exists(select 1 from public.inventory_movements im where im.reference_table = 'purchase_returns' and im.reference_id = pr.id::text),
      'has_journal', exists(
         select 1 
         from public.inventory_movements im 
         join public.journal_entries je on je.source_table = 'inventory_movements' and je.source_id = im.id::text
         where im.reference_table = 'purchase_returns' and im.reference_id = pr.id::text
      )
    )
  )
  into res
  from public.purchase_returns pr
  where not exists(select 1 from public.inventory_movements im where im.reference_table = 'purchase_returns' and im.reference_id = pr.id::text)
     or not exists(
         select 1 
         from public.inventory_movements im 
         join public.journal_entries je on je.source_table = 'inventory_movements' and je.source_id = im.id::text
         where im.reference_table = 'purchase_returns' and im.reference_id = pr.id::text
     );
     
  return coalesce(res, '[]'::jsonb);
end;
$$;

revoke all on function public.diag_get_stuck_po_returns() from public;
grant execute on function public.diag_get_stuck_po_returns() to anon, authenticated;

notify pgrst, 'reload schema';
