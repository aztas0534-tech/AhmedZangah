do $$
declare
  v_state_count int;
  v_acct_count int;
  v_lines_count int;
  v_can_view boolean;
begin
  raise notice '--- DEBUG START ---';

  -- 1. Check permissions (fake check since we are superuser here)
  select public.can_view_reports() into v_can_view;
  raise notice 'can_view_reports: %', v_can_view;

  -- 2. Check State Table
  select count(*) into v_state_count
  from public.base_currency_restatement_state
  where id = 'sar_base_lock';
  
  raise notice 'State table (sar_base_lock) count: %', v_state_count;
  
  if v_state_count = 0 then
    raise notice 'CRITICAL: base_currency_restatement_state is missing "sar_base_lock" row! This causes CROSS JOIN to empty results.';
    -- Try to insert it if missing? 
    -- insert into public.base_currency_restatement_state(id, old_base_currency, locked_at) values ('sar_base_lock', 'SAR', '2025-01-01');
  end if;

  -- 3. Check Account
  select count(*) into v_acct_count
  from public.chart_of_accounts
  where code = '1410';
  raise notice 'Account 1410 count: %', v_acct_count;

  -- 4. Check Raw Lines for 1410
  select count(*) into v_lines_count
  from public.journal_lines jl
  join public.chart_of_accounts coa on coa.id = jl.account_id
  where coa.code = '1410';
  raise notice 'Raw journal lines for 1410: %', v_lines_count;

  -- 5. Test RPC call directly (simulated)
  -- We can't easily call return table function in DO block without temp table or Loop
  -- But we can duplicate the query logic roughly
  
  perform 1; 

  raise notice '--- DEBUG END ---';
end $$;
