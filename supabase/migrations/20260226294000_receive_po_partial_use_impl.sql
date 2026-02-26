set app.allow_ledger_ddl = '1';

create or replace function public.receive_purchase_order_partial(
  p_order_id uuid,
  p_items jsonb,
  p_occurred_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if to_regprocedure('public._receive_purchase_order_partial_impl(uuid,jsonb,timestamptz)') is null then
    raise exception 'receive_po_impl_missing';
  end if;

  return public._receive_purchase_order_partial_impl(p_order_id, p_items, p_occurred_at);
end;
$$;

revoke all on function public.receive_purchase_order_partial(uuid, jsonb, timestamptz) from public;
grant execute on function public.receive_purchase_order_partial(uuid, jsonb, timestamptz) to authenticated;

notify pgrst, 'reload schema';
