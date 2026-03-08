do $$
declare
  v_view record;
begin
  for v_view in 
    select table_name 
    from information_schema.views 
    where table_schema = 'public'
  loop
    begin
      execute format('explain select * from public.%I', v_view.table_name);
    exception when others then
      raise exception 'INVALID VIEW DETECTED THIS IS BREAKING POSTGREST: % - %', v_view.table_name, sqlerrm;
    end;
  end loop;
end $$;
