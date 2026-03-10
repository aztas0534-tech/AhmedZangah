-- ═══════════════════════════════════════════════════════════════
-- Fix order #479F27: change delivery journal line from
-- account 2050 (customer deposits) → 1200 (AR/accounts receivable)
-- Then re-create the party_ledger_entry on 1200
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_order_id uuid;
  v_deposits_id uuid;
  v_ar_id uuid;
  v_je_id uuid;
  v_jl_id uuid;
  v_count int;
begin
  perform set_config('app.allow_ledger_ddl', '1', true);

  -- Find order
  select id into v_order_id
  from public.orders where id::text like '%479f27%' limit 1;
  if v_order_id is null then raise notice 'Order not found'; return; end if;

  -- Find account IDs
  select id into v_deposits_id from public.chart_of_accounts where code = '2050' limit 1;
  select id into v_ar_id from public.chart_of_accounts where code = '1200' limit 1;

  if v_ar_id is null then raise notice 'AR account 1200 not found'; return; end if;

  raise notice 'Order: %, Deposits(2050): %, AR(1200): %', v_order_id, v_deposits_id, v_ar_id;

  -- Disable triggers
  alter table public.journal_lines disable trigger user;
  alter table public.party_ledger_entries disable trigger user;
  alter table public.party_open_items disable trigger user;

  -- Find the order's delivery journal entry
  select je.id into v_je_id
  from public.journal_entries je
  where je.source_table = 'orders' and je.source_id = v_order_id::text
  limit 1;

  if v_je_id is null then
    raise notice 'No journal entry found for order';
    -- Re-enable triggers
    alter table public.journal_lines enable trigger user;
    alter table public.party_ledger_entries enable trigger user;
    alter table public.party_open_items enable trigger user;
    return;
  end if;

  raise notice 'Journal entry: %', v_je_id;

  -- Find journal_line on 2050 for this entry
  select jl.id into v_jl_id
  from public.journal_lines jl
  where jl.journal_entry_id = v_je_id
    and jl.account_id = v_deposits_id
  limit 1;

  if v_jl_id is not null then
    -- Change the account from 2050 → 1200
    update public.journal_lines
    set account_id = v_ar_id
    where id = v_jl_id;

    raise notice 'Changed journal_line % from 2050 to 1200', v_jl_id;

    -- Re-insert the party_ledger_entry for this entry
    perform public.insert_party_ledger_for_entry(v_je_id);
    raise notice 'Re-inserted party_ledger_entry for JE %', v_je_id;
  else
    raise notice 'No journal_line on 2050 found for this entry';

    -- Check if there's already a line on 1200
    select jl.id into v_jl_id
    from public.journal_lines jl
    where jl.journal_entry_id = v_je_id
      and jl.account_id = v_ar_id
    limit 1;

    if v_jl_id is not null then
      raise notice 'Journal_line on 1200 already exists: %', v_jl_id;
      -- Just re-insert the party_ledger_entry
      perform public.insert_party_ledger_for_entry(v_je_id);
      raise notice 'Re-inserted party_ledger_entry for JE %', v_je_id;
    else
      raise notice 'No suitable journal_line found at all';
    end if;
  end if;

  -- Re-enable triggers
  alter table public.journal_lines enable trigger user;
  alter table public.party_ledger_entries enable trigger user;
  alter table public.party_open_items enable trigger user;

  -- Verify
  select count(*) into v_count
  from public.party_ledger_entries ple
  join public.journal_entries je on je.id = ple.journal_entry_id
  join public.chart_of_accounts coa on coa.id = ple.account_id
  where je.source_table = 'orders' and je.source_id = v_order_id::text
    and coa.code = '1200';

  raise notice '=== AR (1200) entries for order: % ===', v_count;
end $$;

notify pgrst, 'reload schema';
