create or replace function public.diag_batch_movement_detailed()
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
      'id', im.id,
      'movement_type', im.movement_type,
      'quantity', im.quantity,
      'reference_table', im.reference_table,
      'reference_id', im.reference_id,
      'data', im.data,
      'created_at', im.created_at,
      'batch_id', im.batch_id
    ) order by im.created_at asc
  )
  into res
  from public.inventory_movements im
  where im.batch_id::text in (
    'ca20926d-9e9c-442a-8662-926e7232d50d',
    '793cae3c-1057-48b5-a36b-af21a9f33dc4',
    '1b80d124-6813-4f6c-b6a7-143fd836addf'
  );
     
  return coalesce(res, '[]'::jsonb);
end;
$$;

revoke all on function public.diag_batch_movement_detailed() from public;
grant execute on function public.diag_batch_movement_detailed() to anon, authenticated;

notify pgrst, 'reload schema';
