create or replace function public.get_function_defs()
returns jsonb
language plpgsql
security definer
as $$
declare
  v_res jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', proname,
    'args', pg_get_function_identity_arguments(oid),
    'src', prosrc
  )), '[]'::jsonb)
  into v_res
  from pg_proc
  where proname in ('deduct_stock_on_delivery_v2', 'confirm_order_delivery', 'confirm_order_delivery_with_credit');
  return v_res;
end;
$$;

revoke all on function public.get_function_defs() from public;
grant execute on function public.get_function_defs() to anon, authenticated;
notify pgrst, 'reload schema';
