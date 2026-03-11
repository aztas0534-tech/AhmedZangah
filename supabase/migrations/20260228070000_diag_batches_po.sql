create or replace function public.diag_check_batches_po()
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
      'quantity_received', b.quantity_received,
      'quantity_consumed', b.quantity_consumed,
      'receipt_id', b.receipt_id,
      'purchase_order_id', pr.purchase_order_id
    )
  )
  into res
  from public.batches b
  left join public.purchase_receipts pr on pr.id = b.receipt_id
  where b.id::text in (
    'ca20926d-9e9c-442a-8662-926e7232d50d',
    '793cae3c-1057-48b5-a36b-af21a9f33dc4',
    '1b80d124-6813-4f6c-b6a7-143fd836addf'
  );
     
  return coalesce(res, '[]'::jsonb);
end;
$$;

revoke all on function public.diag_check_batches_po() from public;
grant execute on function public.diag_check_batches_po() to anon, authenticated;

notify pgrst, 'reload schema';
