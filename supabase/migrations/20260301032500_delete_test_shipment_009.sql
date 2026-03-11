set app.allow_ledger_ddl = '1';

-- Step 1: Reopen the test shipment SHP-20260228-000009 (id: 7f23bb17-d654-4b51-8ce4-238fbf5deb3d)
-- It was created during E2E testing and needs to be removed

-- Set bypass configs
do $$
begin
  perform set_config('app.internal_shipment_close', '1', false);
  perform set_config('app.internal_shipment_reopen', '1', false);
end $$;

-- Delete any journal entries/lines for this shipment
alter table public.journal_lines disable trigger user;
alter table public.journal_entries disable trigger user;
alter table public.ledger_entry_hash_chain disable trigger user;

delete from public.ledger_entry_hash_chain
where journal_entry_id in (
  select id from public.journal_entries
  where source_table = 'import_shipments'
    and source_id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d'
);

delete from public.journal_lines
where journal_entry_id in (
  select id from public.journal_entries
  where source_table = 'import_shipments'
    and source_id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d'
);

delete from public.journal_entries
where source_table = 'import_shipments'
  and source_id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d';

alter table public.journal_lines enable trigger user;
alter table public.journal_entries enable trigger user;
alter table public.ledger_entry_hash_chain enable trigger user;

-- Step 2: Delete shipment items and expenses
delete from public.import_shipments_items
where shipment_id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d';

delete from public.import_expenses
where shipment_id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d';

-- Step 3: Unlink any receipts
update public.purchase_receipts
set import_shipment_id = null
where import_shipment_id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d';

-- Step 4: Set status to draft then delete
update public.import_shipments
set status = 'draft'
where id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d';

-- Clear bypass
do $$
begin
  perform set_config('app.internal_shipment_close', '', false);
  perform set_config('app.internal_shipment_reopen', '', false);
end $$;

-- Step 5: Delete the shipment
delete from public.import_shipments
where id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d';

do $$
begin
  if not exists (select 1 from public.import_shipments where id = '7f23bb17-d654-4b51-8ce4-238fbf5deb3d') then
    raise notice 'OK: Test shipment SHP-20260228-000009 deleted successfully.';
  else
    raise notice 'ERROR: Shipment still exists!';
  end if;
end $$;
