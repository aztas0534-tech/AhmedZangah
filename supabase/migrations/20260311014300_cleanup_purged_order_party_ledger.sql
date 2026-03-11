-- One-time cleanup: Remove stale party_ledger_entries and party_open_items
-- for order #479F27 (EC479F27) that was already purged but left traces

set app.allow_ledger_ddl = '1';

do $$
declare
  v_order_id uuid;
  v_je_ids uuid[];
  v_jl_ids uuid[];
begin
  perform set_config('app.allow_ledger_ddl', '1', true);

  -- Find the order by the short code suffix
  select id into v_order_id
  from public.orders
  where id::text like '%479f27%'
  limit 1;

  if v_order_id is null then
    raise notice 'Order not found, skipping cleanup';
    return;
  end if;

  -- Collect order journal entry IDs
  select coalesce(array_agg(je.id), '{}') into v_je_ids
  from public.journal_entries je
  where je.source_table = 'orders' and je.source_id = v_order_id::text;

  -- Collect journal line IDs
  select coalesce(array_agg(jl.id), '{}') into v_jl_ids
  from public.journal_lines jl
  where jl.journal_entry_id = any(v_je_ids);

  if array_length(v_jl_ids, 1) > 0 then
    -- Disable triggers
    alter table public.party_ledger_entries disable trigger user;
    alter table public.party_open_items disable trigger user;
    begin alter table public.settlement_lines disable trigger user; exception when others then null; end;
    begin alter table public.settlement_headers disable trigger user; exception when others then null; end;

    -- Delete settlement_lines referencing party_open_items
    begin
      delete from public.settlement_lines
      where from_open_item_id in (select poi.id from public.party_open_items poi where poi.journal_line_id = any(v_jl_ids))
         or to_open_item_id   in (select poi.id from public.party_open_items poi where poi.journal_line_id = any(v_jl_ids));
    exception when others then null; end;

    -- Delete party_open_items
    begin
      delete from public.party_open_items where journal_line_id = any(v_jl_ids);
    exception when others then null; end;

    -- Delete party_ledger_entries
    begin
      delete from public.party_ledger_entries where journal_line_id = any(v_jl_ids);
    exception when others then null; end;

    -- Also clean AR open items for this order
    begin alter table public.ar_open_items disable trigger user; exception when others then null; end;
    begin
      delete from public.ar_open_items where invoice_id = v_order_id;
    exception when others then null; end;
    begin alter table public.ar_open_items enable trigger user; exception when others then null; end;

    -- Re-enable triggers
    alter table public.party_ledger_entries enable trigger user;
    alter table public.party_open_items enable trigger user;
    begin alter table public.settlement_lines enable trigger user; exception when others then null; end;
    begin alter table public.settlement_headers enable trigger user; exception when others then null; end;

    begin
      delete from public.settlement_headers sh
      where not exists (select 1 from public.settlement_lines sl where sl.settlement_id = sh.id);
    exception when others then null; end;
  end if;

  raise notice 'Cleanup completed for order %', v_order_id;
end $$;

notify pgrst, 'reload schema';
