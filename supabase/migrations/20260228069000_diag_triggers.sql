create or replace function public.diag_list_triggers()
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
      'trigger_name', t.tgname,
      'table_name', c.relname,
      'function_name', p.proname,
      'trigger_type', t.tgtype
    )
  )
  into res
  from pg_trigger t
  join pg_class c on t.tgrelid = c.oid
  join pg_proc p on t.tgfoid = p.oid
  join pg_namespace n on c.relnamespace = n.oid
  where n.nspname = 'public'
    and c.relname in ('inventory_movements', 'purchase_returns', 'purchase_return_items')
    and not t.tgisinternal;
     
  return coalesce(res, '[]'::jsonb);
end;
$$;

revoke all on function public.diag_list_triggers() from public;
grant execute on function public.diag_list_triggers() to anon, authenticated;

notify pgrst, 'reload schema';
