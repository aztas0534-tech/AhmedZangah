-- Make exec_debug_sql SECURITY DEFINER so it bypasses RLS for diagnostic queries
create or replace function public.exec_debug_sql(q text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  result jsonb;
begin
  execute q into result;
  return result;
exception when others then
  return jsonb_build_object('error', sqlerrm, 'state', sqlstate);
end;
$$;

notify pgrst, 'reload schema';
