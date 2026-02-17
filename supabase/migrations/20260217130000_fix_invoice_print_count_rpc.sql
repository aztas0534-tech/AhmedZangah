create or replace function public.increment_invoice_print_count(
  p_order_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Check if user is staff (admin/cashier/etc)
  if not public.is_staff() then
    raise exception 'access denied';
  end if;

  update public.orders
  set 
    data = jsonb_set(
      jsonb_set(
        data, 
        '{invoicePrintCount}', 
        to_jsonb(coalesce((data->>'invoicePrintCount')::int, 0) + 1)
      ),
      '{invoiceLastPrintedAt}',
      to_jsonb(now())
    )
  where id = p_order_id;
end;
$$;

revoke all on function public.increment_invoice_print_count(uuid) from public;
grant execute on function public.increment_invoice_print_count(uuid) to authenticated;
