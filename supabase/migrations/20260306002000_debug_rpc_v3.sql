create or replace function public.exec_debug_sql(q text)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_res jsonb;
begin
  execute q into v_res;
  return v_res;
exception when others then
  return jsonb_build_object('error', sqlerrm, 'state', sqlstate);
end;
$$;
