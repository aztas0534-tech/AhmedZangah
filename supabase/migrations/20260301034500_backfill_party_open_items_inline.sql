set app.allow_ledger_ddl = '1';

-- Verify current state and fill any remaining gaps
do $$
declare
  v_ple int; v_poi int; v_gap int;
begin
  select count(*) into v_ple from public.party_ledger_entries;
  select count(*) into v_poi from public.party_open_items;
  raise notice 'Current PLE: %, POI: %', v_ple, v_poi;

  -- Count PLEs without matching POI
  select count(*) into v_gap
  from public.party_ledger_entries ple
  left join public.party_open_items poi on poi.journal_line_id = ple.journal_line_id
  where poi.id is null;
  raise notice 'PLE without POI: %', v_gap;
end $$;

-- Fill any remaining gaps inline
insert into public.party_open_items(
  party_id, journal_entry_id, journal_line_id, account_id, direction,
  occurred_at, due_date, item_role, item_type, source_table, source_id,
  source_event, party_document_id, currency_code, foreign_amount,
  base_amount, open_foreign_amount, open_base_amount, status
)
select
  ple.party_id, ple.journal_entry_id, ple.journal_line_id, ple.account_id, ple.direction,
  ple.occurred_at, ple.occurred_at::date,
  psa.role,
  public._party_open_item_type(je.source_table, je.source_event),
  je.source_table, je.source_id, je.source_event,
  case when coalesce(je.source_table,'') = 'party_documents' then nullif(je.source_id,'')::uuid else null end,
  upper(coalesce(ple.currency_code, public.get_base_currency())),
  ple.foreign_amount, ple.base_amount, ple.foreign_amount, ple.base_amount,
  'open'
from public.party_ledger_entries ple
join public.journal_entries je on je.id = ple.journal_entry_id
join public.party_subledger_accounts psa on psa.account_id = ple.account_id and psa.is_active = true
left join public.party_open_items poi on poi.journal_line_id = ple.journal_line_id
where poi.id is null
  and coalesce(je.source_table,'') <> 'settlements'
  and coalesce(je.source_event,'') <> 'realized_fx'
on conflict (journal_line_id) do nothing;

-- Final verification
do $$
declare v_ple int; v_poi int; v_gap int;
begin
  select count(*) into v_ple from public.party_ledger_entries;
  select count(*) into v_poi from public.party_open_items;
  select count(*) into v_gap
  from public.party_ledger_entries ple
  left join public.party_open_items poi on poi.journal_line_id = ple.journal_line_id
  where poi.id is null;
  raise notice '=== FINAL STATE ===';
  raise notice 'party_ledger_entries: %', v_ple;
  raise notice 'party_open_items: %', v_poi;
  raise notice 'Remaining gaps: %', v_gap;
end $$;
