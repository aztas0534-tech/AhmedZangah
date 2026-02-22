set app.allow_ledger_ddl = '1';

do $$
declare
  v_acct uuid;
begin
  select a.id
  into v_acct
  from public.chart_of_accounts a
  where a.code = '2120'
  limit 1;

  if v_acct is not null then
    insert into public.party_subledger_accounts(account_id, role, is_active)
    values (v_acct, 'ap', true)
    on conflict (account_id) do update
      set role = excluded.role,
          is_active = excluded.is_active;
  end if;
end $$;

notify pgrst, 'reload schema';
