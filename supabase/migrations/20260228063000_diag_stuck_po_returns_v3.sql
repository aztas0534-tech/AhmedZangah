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
      'movement_qty', im.quantity,
      'movement_cost', im.total_cost,
      'journal_id', je.id,
      'journal_lines_count', (select count(*) from public.journal_lines jl where jl.journal_entry_id = je.id),
      'journal_total_debit', (select sum(debit) from public.journal_lines jl where jl.journal_entry_id = je.id)
    )
  )
  into res
  from public.purchase_returns pr
  left join public.inventory_movements im on im.reference_table = 'purchase_returns' and im.reference_id = pr.id::text
  left join public.journal_entries je on je.source_table = 'inventory_movements' and je.source_id = im.id::text;
     
  return coalesce(res, '[]'::jsonb);
end;
$$;
