-- ============================================================================
-- Nuclear fix: Re-post all delivery journal entries
-- Uses TRUNCATE CASCADE to handle all FK chains automatically
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- Disable user triggers on all affected tables
alter table public.journal_lines disable trigger user;
alter table public.journal_entries disable trigger user;
alter table public.party_ledger_entries disable trigger user;
alter table public.settlement_lines disable trigger user;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    alter table public.party_open_items disable trigger user;
  end if;
  if to_regclass('public.ar_open_items') is not null then
    alter table public.ar_open_items disable trigger user;
  end if;
  if to_regclass('public.ledger_entry_hash_chain') is not null then
    alter table public.ledger_entry_hash_chain disable trigger user;
  end if;
end $$;

-- Use TRUNCATE CASCADE on the root tables to clear everything
-- that depends on journal_entries/journal_lines
truncate public.party_ledger_entries cascade;
truncate public.party_open_items cascade;

do $$
begin
  if to_regclass('public.ar_open_items') is not null then
    truncate public.ar_open_items cascade;
  end if;
  if to_regclass('public.ledger_entry_hash_chain') is not null then
    truncate public.ledger_entry_hash_chain cascade;
  end if;
end $$;

-- Now delete order delivery journal entries (no more FK blockers)
delete from public.journal_lines jl
using public.journal_entries je
where jl.journal_entry_id = je.id
  and je.source_table = 'orders'
  and je.source_event in ('delivered', 'invoiced', 'reversal', 'void');

delete from public.journal_entries je
where je.source_table = 'orders'
  and je.source_event in ('delivered', 'invoiced', 'reversal', 'void');

-- Re-post all delivered orders
do $$
declare
  v_rec record;
  v_posted int := 0;
  v_errors int := 0;
  v_ple_count int := 0;
  v_poi_count int := 0;
begin
  raise notice 'Re-posting delivery for all delivered orders...';

  for v_rec in
    select o.id, o.invoice_number
    from public.orders o
    where o.status = 'delivered'
    order by o.created_at asc
  loop
    begin
      perform public.post_order_delivery(v_rec.id);
      v_posted := v_posted + 1;
    exception when others then
      raise notice 'Error posting order % (%): %', v_rec.id, v_rec.invoice_number, sqlerrm;
      v_errors := v_errors + 1;
    end;
  end loop;

  raise notice 'Deliveries posted: %, errors: %', v_posted, v_errors;

  -- Rebuild party_ledger_entries
  raise notice 'Rebuilding party_ledger_entries...';
  v_ple_count := coalesce(public.backfill_party_ledger_for_existing_entries(50000, null), 0);
  raise notice 'Rebuilt % party_ledger_entries', v_ple_count;

  -- Rebuild party_open_items
  raise notice 'Rebuilding party_open_items...';
  insert into public.party_open_items(
    party_id, journal_entry_id, journal_line_id, account_id,
    direction, occurred_at, due_date, item_role, item_type,
    source_table, source_id, source_event, party_document_id,
    currency_code, foreign_amount, base_amount,
    open_foreign_amount, open_base_amount, status
  )
  select
    ple.party_id, ple.journal_entry_id, ple.journal_line_id, ple.account_id,
    ple.direction, ple.occurred_at, ple.occurred_at::date,
    psa.role,
    public._party_open_item_type(je.source_table, je.source_event),
    je.source_table, je.source_id, je.source_event,
    case when coalesce(je.source_table,'') = 'party_documents'
      then nullif(je.source_id,'')::uuid else null end,
    ple.currency_code,
    ple.foreign_amount, ple.base_amount,
    ple.foreign_amount, ple.base_amount, 'open'
  from public.party_ledger_entries ple
  join public.journal_entries je on je.id = ple.journal_entry_id
  join public.party_subledger_accounts psa
    on psa.account_id = ple.account_id and psa.is_active = true
  where coalesce(je.source_table,'') <> 'settlements'
    and coalesce(je.source_event,'') <> 'realized_fx'
  on conflict (journal_line_id) do nothing;

  raise notice '=== COMPLETE ===';
  select count(*) into v_ple_count from public.party_ledger_entries;
  select count(*) into v_poi_count from public.party_open_items;
  raise notice 'Final PLE: %, POI: %', v_ple_count, v_poi_count;
end $$;

-- Re-enable user triggers
alter table public.journal_lines enable trigger user;
alter table public.journal_entries enable trigger user;
alter table public.party_ledger_entries enable trigger user;
alter table public.settlement_lines enable trigger user;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    alter table public.party_open_items enable trigger user;
  end if;
  if to_regclass('public.ar_open_items') is not null then
    alter table public.ar_open_items enable trigger user;
  end if;
  if to_regclass('public.ledger_entry_hash_chain') is not null then
    alter table public.ledger_entry_hash_chain enable trigger user;
  end if;
end $$;

notify pgrst, 'reload schema';
