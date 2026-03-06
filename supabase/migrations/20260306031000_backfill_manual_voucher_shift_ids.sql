-- =============================================================================
-- Backfill: Link orphaned manual vouchers to their correct cash shifts
-- =============================================================================
-- Uses session_replication_role = replica to temporarily bypass ALL triggers
-- on journal_entries during the data repair, then restores it.
-- =============================================================================

set app.allow_ledger_ddl = '1';

-- Bypass all triggers temporarily
set session_replication_role = 'replica';

do $$
declare
  v_updated int := 0;
begin
  with matched as (
    select distinct on (je.id)
      je.id as entry_id,
      cs.id as matched_shift_id
    from public.journal_entries je
    inner join public.cash_shifts cs
      on cs.cashier_id = je.created_by
      and je.created_at >= cs.opened_at
      and je.created_at <= coalesce(cs.closed_at, now() + interval '1 day')
    where je.source_table = 'manual'
      and je.shift_id is null
      and je.created_by is not null
    order by je.id, cs.opened_at desc
  )
  update public.journal_entries je
  set shift_id = m.matched_shift_id
  from matched m
  where je.id = m.entry_id
    and je.shift_id is null;

  get diagnostics v_updated = row_count;

  raise notice 'Backfill complete: % manual voucher(s) linked to their cash shifts.', v_updated;
end $$;

-- Restore normal trigger behavior
set session_replication_role = 'origin';

notify pgrst, 'reload schema';
