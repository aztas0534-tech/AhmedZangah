set app.allow_ledger_ddl = '1';

do $$
declare
  v_rec record;
begin
  for v_rec in
    select coa.id, coa.code
    from public.chart_of_accounts coa
    where coa.code ~ '^(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)-(1020|1030)-[0-9]{3}$'
       or coa.code ~ '^(1020|1030)\.[0-9]+$'
  loop
    if exists (
      select 1
      from public.app_settings s
      cross join lateral jsonb_each_text(coalesce(s.data->'settings'->'accounting_accounts', '{}'::jsonb)) e
      where e.value = v_rec.id::text
    ) then
      continue;
    end if;

    begin
      delete from public.chart_of_accounts
      where id = v_rec.id;
    exception when foreign_key_violation then
      update public.chart_of_accounts
      set is_active = false
      where id = v_rec.id;
    end;
  end loop;
end $$;

notify pgrst, 'reload schema';
