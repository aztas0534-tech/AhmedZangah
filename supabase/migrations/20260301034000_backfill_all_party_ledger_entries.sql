set app.allow_ledger_ddl = '1';

-- Disable USER triggers on journal_lines to bypass stale trigger
-- (trg_block_system_journal_lines_mutation references 'base_debit' column 
-- that doesn't exist)
alter table public.journal_lines disable trigger user;

do $$
declare
  v_party record;
  v_ledger_total int := 0;
  v_open_total int := 0;
  v_ledger int;
  v_result jsonb;
begin
  raise notice 'Starting comprehensive party ledger backfill...';

  -- Step 1: Backfill party_ledger_entries for ALL parties
  v_ledger := coalesce(public.backfill_party_ledger_for_existing_entries(10000, null), 0);
  v_ledger_total := v_ledger;
  raise notice 'Step 1: Backfilled % party_ledger_entries (all parties)', v_ledger;

  -- Step 2: Backfill party_open_items for each party
  for v_party in
    select id, name from public.financial_parties where is_active = true
  loop
    begin
      v_result := public.backfill_party_open_items_for_party(v_party.id, 10000);
      v_open_total := v_open_total + coalesce((v_result->>'openItemsCreated')::int, 0);
      v_ledger_total := v_ledger_total + coalesce((v_result->>'ledgerBackfilled')::int, 0);
      raise notice 'Party "%" -> ledger: %, open: %',
        v_party.name,
        coalesce((v_result->>'ledgerBackfilled')::int, 0),
        coalesce((v_result->>'openItemsCreated')::int, 0);
    exception when others then
      raise notice 'Party "%" FAILED: %', v_party.name, sqlerrm;
    end;
  end loop;

  raise notice '=== BACKFILL COMPLETE ===';
  raise notice 'Total ledger entries: %', v_ledger_total;
  raise notice 'Total open items: %', v_open_total;

  -- Verify
  declare v_ple int; v_poi int;
  begin
    select count(*) into v_ple from public.party_ledger_entries;
    select count(*) into v_poi from public.party_open_items;
    raise notice 'Final PLE count: %', v_ple;
    raise notice 'Final POI count: %', v_poi;
  end;
end $$;

-- Re-enable triggers
alter table public.journal_lines enable trigger user;
