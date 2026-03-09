-- ============================================================================
-- Find ALL cancelled orders that still have unreversed journal entries
-- (payments or deliveries) and void/reverse them.
-- Then rebuild party_ledger_entries and party_open_items.
-- ============================================================================

set app.allow_ledger_ddl = '1';

alter table public.journal_lines disable trigger user;
alter table public.party_ledger_entries disable trigger user;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    alter table public.party_open_items disable trigger user;
  end if;
end $$;

do $$
declare
  v_base text;
  v_rec record;
  v_je record;
  v_reversed_payments int := 0;
  v_reversed_deliveries int := 0;
  v_orphan_payments int := 0;
begin
  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));
  raise notice 'Base currency: %', v_base;

  -- ====================================================================
  -- STEP 1: Find cancelled orders with unreversed PAYMENT journal entries
  -- ====================================================================
  raise notice 'Step 1: Finding cancelled orders with unreversed payment entries...';

  for v_rec in
    select
      o.id as order_id,
      o.invoice_number,
      p.id as payment_id,
      je.id as je_id,
      je.source_event
    from public.orders o
    join public.payments p
      on p.reference_table = 'orders'
      and p.reference_id = o.id::text
      and p.direction = 'in'
    join public.journal_entries je
      on je.source_table = 'payments'
      and je.source_id = p.id::text
      and je.source_event not in ('reversal', 'void', 'reversed')
    where o.status = 'cancelled'
      -- Make sure there's no existing reversal for this entry
      and not exists (
        select 1 from public.journal_entries je2
        where je2.source_table = 'payments'
          and je2.source_id = p.id::text
          and je2.source_event in ('reversal', 'void', 'reversed')
      )
  loop
    begin
      raise notice 'Reversing payment JE % for cancelled order % (payment %)',
        v_rec.je_id, v_rec.order_id, v_rec.payment_id;

      -- Create a reversal journal entry
      declare
        v_new_je_id uuid;
        v_line record;
      begin
        insert into public.journal_entries(
          entry_date, memo, source_table, source_id, source_event,
          status, currency_code, fx_rate
        )
        select
          now(),
          'عكس دفعة (طلب ملغي) - ' || coalesce(v_rec.invoice_number, right(v_rec.order_id::text, 6)),
          je.source_table,
          je.source_id,
          'reversal',
          'posted',
          je.currency_code,
          je.fx_rate
        from public.journal_entries je
        where je.id = v_rec.je_id
        returning id into v_new_je_id;

        -- Create reversed journal lines (swap debit/credit)
        for v_line in
          select * from public.journal_lines jl where jl.journal_entry_id = v_rec.je_id
        loop
          insert into public.journal_lines(
            journal_entry_id, account_id, debit, credit, line_memo,
            party_id, currency_code, fx_rate, foreign_amount
          )
          values (
            v_new_je_id,
            v_line.account_id,
            coalesce(v_line.credit, 0),  -- swap: old credit → new debit
            coalesce(v_line.debit, 0),   -- swap: old debit → new credit
            'عكس: ' || coalesce(v_line.line_memo, ''),
            v_line.party_id,
            v_line.currency_code,
            v_line.fx_rate,
            v_line.foreign_amount
          );
        end loop;

        v_reversed_payments := v_reversed_payments + 1;
      end;
    exception when others then
      raise notice 'Error reversing payment JE %: %', v_rec.je_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 1 done: reversed % payment entries for cancelled orders', v_reversed_payments;

  -- ====================================================================
  -- STEP 2: Find cancelled orders with unreversed DELIVERY journal entries
  -- (these shouldn't normally exist because delivery changes status to
  -- 'delivered' which prevents cancellation, but just in case)
  -- ====================================================================
  raise notice 'Step 2: Finding cancelled orders with unreversed delivery entries...';

  for v_rec in
    select
      o.id as order_id,
      o.invoice_number,
      je.id as je_id,
      je.source_event
    from public.orders o
    join public.journal_entries je
      on je.source_table = 'orders'
      and je.source_id = o.id::text
      and je.source_event in ('delivered', 'invoiced')
    where o.status = 'cancelled'
      and not exists (
        select 1 from public.journal_entries je2
        where je2.source_table = 'orders'
          and je2.source_id = o.id::text
          and je2.source_event in ('reversal', 'void', 'reversed')
      )
  loop
    begin
      raise notice 'Reversing delivery JE % for cancelled order %',
        v_rec.je_id, v_rec.order_id;

      declare
        v_new_je_id uuid;
        v_line record;
      begin
        insert into public.journal_entries(
          entry_date, memo, source_table, source_id, source_event,
          status, currency_code, fx_rate
        )
        select
          now(),
          'عكس تسليم (طلب ملغي) - ' || coalesce(v_rec.invoice_number, right(v_rec.order_id::text, 6)),
          je.source_table,
          je.source_id,
          'reversal',
          'posted',
          je.currency_code,
          je.fx_rate
        from public.journal_entries je
        where je.id = v_rec.je_id
        returning id into v_new_je_id;

        for v_line in
          select * from public.journal_lines jl where jl.journal_entry_id = v_rec.je_id
        loop
          insert into public.journal_lines(
            journal_entry_id, account_id, debit, credit, line_memo,
            party_id, currency_code, fx_rate, foreign_amount
          )
          values (
            v_new_je_id,
            v_line.account_id,
            coalesce(v_line.credit, 0),
            coalesce(v_line.debit, 0),
            'عكس: ' || coalesce(v_line.line_memo, ''),
            v_line.party_id,
            v_line.currency_code,
            v_line.fx_rate,
            v_line.foreign_amount
          );
        end loop;

        v_reversed_deliveries := v_reversed_deliveries + 1;
      end;
    exception when others then
      raise notice 'Error reversing delivery JE %: %', v_rec.je_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 2 done: reversed % delivery entries for cancelled orders', v_reversed_deliveries;

  -- ====================================================================
  -- STEP 3: Find orphan payment journal entries (payments whose
  --         reference order no longer exists or is not found)
  -- ====================================================================
  raise notice 'Step 3: Finding orphan payment entries...';

  for v_rec in
    select
      p.id as payment_id,
      p.reference_id,
      je.id as je_id
    from public.payments p
    join public.journal_entries je
      on je.source_table = 'payments'
      and je.source_id = p.id::text
      and je.source_event not in ('reversal', 'void', 'reversed')
    where p.reference_table = 'orders'
      and p.reference_id is not null
      and not exists (
        select 1 from public.orders o where o.id = (p.reference_id)::uuid
      )
      and not exists (
        select 1 from public.journal_entries je2
        where je2.source_table = 'payments'
          and je2.source_id = p.id::text
          and je2.source_event in ('reversal', 'void', 'reversed')
      )
  loop
    begin
      raise notice 'Orphan payment JE % (payment %, missing order %)',
        v_rec.je_id, v_rec.payment_id, v_rec.reference_id;
      v_orphan_payments := v_orphan_payments + 1;
    exception when others then
      null;
    end;
  end loop;

  raise notice 'Step 3 done: found % orphan payment entries', v_orphan_payments;

  -- ====================================================================
  -- STEP 4: Rebuild party_ledger_entries
  -- ====================================================================
  raise notice 'Step 4: Rebuilding party_ledger_entries...';
  delete from public.party_ledger_entries;

  declare v_ple_count int;
  begin
    v_ple_count := coalesce(public.backfill_party_ledger_for_existing_entries(50000, null), 0);
    raise notice 'Rebuilt % party_ledger_entries', v_ple_count;
  end;

  -- ====================================================================
  -- STEP 5: Re-sync party_open_items
  -- ====================================================================
  raise notice 'Step 5: Syncing party_open_items...';

  -- Delete open items that now have reversal counterparts
  -- (their net effect should be zero)

  -- Insert missing
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
  left join public.party_open_items poi on poi.journal_line_id = ple.journal_line_id
  where poi.id is null
    and coalesce(je.source_table,'') <> 'settlements'
    and coalesce(je.source_event,'') <> 'realized_fx'
  on conflict (journal_line_id) do nothing;

  -- Update existing
  update public.party_open_items poi
  set currency_code       = ple.currency_code,
      foreign_amount      = ple.foreign_amount,
      base_amount         = ple.base_amount,
      open_foreign_amount = ple.foreign_amount,
      open_base_amount    = ple.base_amount
  from public.party_ledger_entries ple
  where poi.journal_line_id = ple.journal_line_id
    and (
      poi.currency_code is distinct from ple.currency_code
      or poi.foreign_amount is distinct from ple.foreign_amount
      or poi.base_amount is distinct from ple.base_amount
    );

  raise notice '=== COMPLETE ===';
  raise notice 'Reversed payments: %', v_reversed_payments;
  raise notice 'Reversed deliveries: %', v_reversed_deliveries;
  raise notice 'Orphan payments found: %', v_orphan_payments;

  declare v_ple int; v_poi int;
  begin
    select count(*) into v_ple from public.party_ledger_entries;
    select count(*) into v_poi from public.party_open_items;
    raise notice 'Final PLE count: %', v_ple;
    raise notice 'Final POI count: %', v_poi;
  end;
end $$;

alter table public.journal_lines enable trigger user;
alter table public.party_ledger_entries enable trigger user;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    alter table public.party_open_items enable trigger user;
  end if;
end $$;

notify pgrst, 'reload schema';
