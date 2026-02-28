create or replace function public.diag_check_batch_balance()
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
      'batch_id', bb.batch_id,
      'warehouse_id', bb.warehouse_id,
      'item_id', bb.item_id,
      'available_qty', bb.quantity,
      'batch_qty_received', b.quantity_received,
      'batch_qty_consumed', b.quantity_consumed
    )
  )
  into res
  from public.batch_balances bb
  join public.batches b on b.id = bb.batch_id
  where bb.batch_id::text in (
    'ca20926d-9e9c-442a-8662-926e7232d50d',
    '793cae3c-1057-48b5-a36b-af21a9f33dc4',
    '1b80d124-6813-4f6c-b6a7-143fd836addf'
  );
     
  return coalesce(res, '[]'::jsonb);
end;
$$;

revoke all on function public.diag_check_batch_balance() from public;
grant execute on function public.diag_check_batch_balance() to anon, authenticated;

notify pgrst, 'reload schema';
