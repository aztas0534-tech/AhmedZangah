-- Diagnostic + force cleanup for ALL deposit (2050) entries related to order #479F27
-- Also check payment BEFA50BC

set app.allow_ledger_ddl = '1';

do $$
declare
  v_order_id uuid;
  v_deposits_account_id uuid;
  v_count int;
  v_ple record;
begin
  perform set_config('app.allow_ledger_ddl', '1', true);

  -- Find order
  select id into v_order_id
  from public.orders where id::text like '%479f27%' limit 1;

  raise notice '=== ORDER ID: % ===', v_order_id;

  -- Find deposits account
  select id into v_deposits_account_id
  from public.chart_of_accounts where code = '2050' limit 1;

  raise notice '=== DEPOSITS ACCOUNT: % ===', v_deposits_account_id;

  -- Diagnostic: show ALL party_ledger_entries for order journal entries
  raise notice '=== PARTY LEDGER ENTRIES FROM ORDER JOURNAL ENTRIES ===';
  for v_ple in
    select ple.id, ple.journal_entry_id, ple.journal_line_id,
           ple.account_id, ple.direction, ple.base_amount,
           coa.code as acct_code,
           je.source_table, je.source_id, je.source_event
    from public.party_ledger_entries ple
    join public.journal_entries je on je.id = ple.journal_entry_id
    join public.chart_of_accounts coa on coa.id = ple.account_id
    where je.source_table = 'orders' and je.source_id = v_order_id::text
  loop
    raise notice 'PLE: id=% acct=% dir=% amt=% src=%/% event=%',
      right(v_ple.id::text, 8), v_ple.acct_code, v_ple.direction,
      v_ple.base_amount, v_ple.source_table, right(v_ple.source_id, 8),
      v_ple.source_event;
  end loop;

  -- Diagnostic: show ALL party_ledger_entries that mention account 2050
  -- for journal entries related to this order OR payments for this order
  raise notice '=== PARTY LEDGER ENTRIES ON 2050 FROM PAYMENTS ===';
  for v_ple in
    select ple.id, ple.journal_entry_id, ple.journal_line_id,
           ple.direction, ple.base_amount,
           je.source_table, je.source_id, je.source_event
    from public.party_ledger_entries ple
    join public.journal_entries je on je.id = ple.journal_entry_id
    where ple.account_id = v_deposits_account_id
      and je.source_table = 'payments'
      and je.source_id in (
        select p.id::text from public.payments p
        where p.reference_table = 'orders' and p.reference_id = v_order_id::text
      )
  loop
    raise notice 'PLE-PAY: id=% dir=% amt=% src=%/% event=%',
      right(v_ple.id::text, 8), v_ple.direction, v_ple.base_amount,
      v_ple.source_table, right(v_ple.source_id, 8), v_ple.source_event;
  end loop;

  -- Now FORCE cleanup: delete ALL party_ledger_entries on 2050 from order entries
  alter table public.party_ledger_entries disable trigger user;
  alter table public.party_open_items disable trigger user;
  begin alter table public.settlement_lines disable trigger user; exception when others then null; end;

  -- Delete party_ledger_entries on 2050 from ORDER journal entries
  delete from public.party_ledger_entries
  where account_id = v_deposits_account_id
    and journal_entry_id in (
      select je.id from public.journal_entries je
      where je.source_table = 'orders' and je.source_id = v_order_id::text
    );
  get diagnostics v_count = row_count;
  raise notice 'DELETED % party_ledger_entries on 2050 from ORDER entries', v_count;

  -- Also delete any remaining payment party_ledger_entries on 2050
  delete from public.party_ledger_entries
  where account_id = v_deposits_account_id
    and journal_entry_id in (
      select je.id from public.journal_entries je
      where je.source_table = 'payments'
        and je.source_id in (
          select p.id::text from public.payments p
          where p.reference_table = 'orders' and p.reference_id = v_order_id::text
        )
    );
  get diagnostics v_count = row_count;
  raise notice 'DELETED % party_ledger_entries on 2050 from PAYMENT entries', v_count;

  -- Also clean party_open_items on 2050
  begin
    delete from public.party_open_items
    where account_id = v_deposits_account_id
      and journal_line_id in (
        select jl.id from public.journal_lines jl
        join public.journal_entries je on je.id = jl.journal_entry_id
        where je.source_table = 'orders' and je.source_id = v_order_id::text
          and jl.account_id = v_deposits_account_id
      );
    get diagnostics v_count = row_count;
    raise notice 'DELETED % party_open_items on 2050', v_count;
  exception when others then
    raise notice 'party_open_items cleanup: %', sqlerrm;
  end;

  alter table public.party_ledger_entries enable trigger user;
  alter table public.party_open_items enable trigger user;
  begin alter table public.settlement_lines enable trigger user; exception when others then null; end;

  -- Verify: count remaining entries on 2050 for this order
  select count(*) into v_count
  from public.party_ledger_entries ple
  join public.journal_entries je on je.id = ple.journal_entry_id
  where ple.account_id = v_deposits_account_id
    and je.source_table = 'orders' and je.source_id = v_order_id::text;

  raise notice '=== REMAINING 2050 entries for order: % ===', v_count;
end $$;

notify pgrst, 'reload schema';
