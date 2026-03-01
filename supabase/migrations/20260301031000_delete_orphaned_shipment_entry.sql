set app.allow_ledger_ddl = '1';

-- Disable USER triggers on all affected tables
alter table public.journal_lines disable trigger user;
alter table public.journal_entries disable trigger user;
alter table public.ledger_entry_hash_chain disable trigger user;

-- Delete the orphaned entry from deleted shipment SHP-20260228-000009
-- Order: hash chain → lines → entry (respect FK constraints)
delete from public.ledger_entry_hash_chain
where journal_entry_id = '503215a5-8127-4de1-9da1-36783a4f16d7';

delete from public.journal_lines
where journal_entry_id = '503215a5-8127-4de1-9da1-36783a4f16d7';

delete from public.journal_entries
where id = '503215a5-8127-4de1-9da1-36783a4f16d7';

-- Re-enable USER triggers
alter table public.journal_lines enable trigger user;
alter table public.journal_entries enable trigger user;
alter table public.ledger_entry_hash_chain enable trigger user;

-- Verify
do $$
declare v int;
begin
  select count(*) into v
  from public.journal_entries je
  where je.source_table = 'import_shipments'
    and not exists (select 1 from public.import_shipments s where s.id::text = je.source_id);
  raise notice 'Orphaned shipment entries remaining: %', v;
end $$;
