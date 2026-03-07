create or replace function public.debug_payment_insert()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_err text;
  v_ctx text;
begin
  begin
    insert into public.payments(id, direction, method, amount, base_amount, currency, reference_table, reference_id)
    values (gen_random_uuid(), 'in', 'ar', 100, 100, 'YER', 'orders', gen_random_uuid()::text);
    return jsonb_build_object('success', true);
  exception when others then
    get stacked diagnostics v_err = message_text, v_ctx = pg_exception_context;
    return jsonb_build_object('error', v_err, 'context', v_ctx);
  end;
end;
$$;
revoke all on function public.debug_payment_insert() from public;
grant execute on function public.debug_payment_insert() to anon, authenticated;
notify pgrst, 'reload schema';
