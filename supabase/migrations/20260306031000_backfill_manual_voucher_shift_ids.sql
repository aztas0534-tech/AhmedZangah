-- =============================================================================
-- Backfill: Link orphaned manual vouchers to their correct cash shifts
-- =============================================================================
-- Strategy:
--   For each journal_entry where source_table = 'manual' AND shift_id IS NULL,
--   find the cash_shift that was OPEN for that user (created_by = cashier_id)
--   at the time the voucher was created (created_at BETWEEN opened_at AND
--   COALESCE(closed_at, 'infinity')).
--
--   If multiple shifts match (edge case), pick the one with the latest opened_at.
--   If no shift matches, the voucher remains unlinked (NULL) — this is expected
--   for vouchers created when no shift was open.
-- =============================================================================

set app.allow_ledger_ddl = '1';

do $$
declare
  v_updated int := 0;
begin
  -- Temporarily allow updates on journal_entries
  set local app.allow_ledger_ddl = '1';

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

notify pgrst, 'reload schema';
