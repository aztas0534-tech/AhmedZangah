set app.allow_ledger_ddl = '1';
create or replace function public.diag_payments_triggers()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'tgname', tgname,
    'tgdef', pg_get_triggerdef(oid)
  )), '[]'::jsonb)
  into v_res
  from pg_trigger
  where tgrelid = 'public.payments'::regclass;
  return v_res;
end;
$$;
revoke all on function public.diag_payments_triggers() from public;
grant execute on function public.diag_payments_triggers() to anon, authenticated;
notify pgrst, 'reload schema';
