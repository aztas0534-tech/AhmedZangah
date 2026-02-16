-- Rebuild Party Ledger for Parties with Currency Mismatches
-- This script detects parties where the Journal Line currency differs from the Party Ledger Entry currency (due to recent backfill).
-- It then wipes the Party Ledger for those parties and rebuilds it to ensure Running Balance and Currency Fields are correct.

BEGIN;

-- Temporarily allow deleting from party_ledger_entries
set app.allow_ledger_ddl = '1';
alter table public.party_ledger_entries disable trigger trg_party_ledger_entries_append_only;

DO $$
DECLARE
  v_party_id uuid;
  v_count int;
  v_affected_parties uuid[];
BEGIN
  -- 1. Identify Affected Parties
  -- Find PLEs where currency_code does NOT match the Journal Line currency code
  select array_agg(distinct ple.party_id)
  into v_affected_parties
  from public.party_ledger_entries ple
  join public.journal_lines jl on jl.id = ple.journal_line_id
  where 
    -- Case 1: PLE says one currency, GL says another (e.g. SAR vs USD)
    upper(ple.currency_code) <> upper(coalesce(jl.currency_code, public.get_base_currency()))
    -- Case 2: PLE missing foreign amount when GL has it
    or (ple.foreign_amount is null and jl.foreign_amount is not null)
    -- Case 3: PLE has different foreign amount
    or (ple.foreign_amount <> jl.foreign_amount);

  IF v_affected_parties is not null THEN
    FOREACH v_party_id IN ARRAY v_affected_parties LOOP
      RAISE NOTICE 'Rebuilding Ledger for Party: %', v_party_id;

      -- 2. Delete ALL entries for this party (to clean slate and fix running balance)
      DELETE FROM public.party_ledger_entries
      WHERE party_id = v_party_id;

      -- 3. Rebuild (Backfill)
      -- This RPC iterates over GL lines and calls insert_party_ledger_for_entry
      -- We bump the batch size to ensure we get all entries
      perform public.backfill_party_ledger_for_existing_entries(100000, v_party_id);
      
      -- 4. Sync Open Items (Safe Mode: Only fully open items)
      -- Update open items to match the newly rebuilt ledger entries
      UPDATE public.party_open_items poi
      SET 
        currency_code = ple.currency_code,
        foreign_amount = ple.foreign_amount,
        open_foreign_amount = ple.foreign_amount,
        base_amount = ple.base_amount,
        open_base_amount = ple.base_amount
      FROM public.party_ledger_entries ple
      WHERE poi.journal_line_id = ple.journal_line_id
        AND poi.party_id = v_party_id
        AND poi.status = 'open' -- Only touch fully open items to avoid breaking settlements
        AND (
             poi.currency_code IS DISTINCT FROM ple.currency_code 
          OR poi.foreign_amount IS DISTINCT FROM ple.foreign_amount
        );

    END LOOP;
  ELSE
    RAISE NOTICE 'No parties checked for mismatches.';
  END IF;

END $$;

-- Enable triggers
alter table public.party_ledger_entries enable trigger trg_party_ledger_entries_append_only;

COMMIT;
