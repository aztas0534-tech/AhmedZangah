-- ============================================================================
-- Fix: Payments incorrectly tagged as YER when they were actually SAR.
-- Detection: if journal_line has currency_code <> base AND
--            foreign_amount ≈ debit/credit (i.e. no real FX conversion),
--            then the payment was in base currency and the currency tag is wrong.
--
-- Also fixes: party_open_items.open_foreign_amount being 0 when it should
--             match the foreign_amount from the party_ledger_entry.
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
  v_fixed_jl int := 0;
  v_rec record;
begin
  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));
  raise notice 'Base currency: %', v_base;

  -- ====================================================================
  -- STEP 1: Fix journal_lines for PAYMENTS where foreign_amount was
  --         incorrectly set to the same value as base amount.
  --         This happens when a SAR payment got tagged as YER because
  --         the linked order was in YER.
  --
  --         Detection rule: if currency_code <> base AND
  --         abs(foreign_amount - greatest(debit, credit)) < 1.0
  --         then the amounts are identical = no real conversion = base currency
  -- ====================================================================
  raise notice 'Step 1: Fixing payment journal_lines with wrong currency tag...';

  for v_rec in
    select
      jl.id as jl_id,
      jl.currency_code as jl_currency,
      jl.foreign_amount,
      jl.debit,
      jl.credit,
      je.source_table,
      je.source_id
    from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    where je.source_table = 'payments'
      and jl.currency_code is not null
      and upper(jl.currency_code) <> upper(v_base)
      -- The key detection: foreign_amount is approximately equal to
      -- the base amount (debit or credit), meaning no conversion happened
      and abs(coalesce(jl.foreign_amount, 0) - greatest(coalesce(jl.debit, 0), coalesce(jl.credit, 0))) < 1.0
  loop
    begin
      declare
        v_pay record;
        v_pay_currency text;
      begin
        select p.currency, p.amount, p.base_amount, p.fx_rate
        into v_pay
        from public.payments p
        where p.id = (v_rec.source_id)::uuid;

        if not found then continue; end if;

        v_pay_currency := upper(nullif(btrim(coalesce(v_pay.currency, '')), ''));

        -- If the payment itself has no currency or is in base currency,
        -- then clear the foreign currency tag from the journal line
        if v_pay_currency is null or v_pay_currency = v_base then
          update public.journal_lines
          set currency_code  = null,
              fx_rate        = null,
              foreign_amount = null
          where id = v_rec.jl_id;
          v_fixed_jl := v_fixed_jl + 1;
          raise notice 'Cleared wrong currency on JL % (payment %)', v_rec.jl_id, v_rec.source_id;
        -- If the payment IS in a foreign currency, fix the foreign_amount
        -- to use the actual payment amount (not the base amount)
        elsif v_pay_currency <> v_base then
          update public.journal_lines
          set currency_code  = v_pay_currency,
              fx_rate        = coalesce(v_pay.fx_rate, 1),
              foreign_amount = abs(coalesce(v_pay.amount, 0))
          where id = v_rec.jl_id;
          v_fixed_jl := v_fixed_jl + 1;
          raise notice 'Fixed foreign amount on JL % (payment %)', v_rec.jl_id, v_rec.source_id;
        end if;
      end;
    exception when others then
      raise notice 'Error fixing JL %: %', v_rec.jl_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 1 complete: fixed % journal_lines', v_fixed_jl;

  -- ====================================================================
  -- STEP 2: Also fix ORDER journal_lines with the same problem
  -- ====================================================================
  raise notice 'Step 2: Fixing order journal_lines with wrong currency tag...';

  for v_rec in
    select
      jl.id as jl_id,
      jl.currency_code as jl_currency,
      jl.foreign_amount,
      jl.debit,
      jl.credit,
      je.source_id
    from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    join public.party_subledger_accounts psa
      on psa.account_id = jl.account_id and psa.is_active = true
    where je.source_table = 'orders'
      and jl.currency_code is not null
      and upper(jl.currency_code) <> upper(v_base)
      and abs(coalesce(jl.foreign_amount, 0) - greatest(coalesce(jl.debit, 0), coalesce(jl.credit, 0))) < 1.0
  loop
    begin
      declare
        v_order record;
        v_data jsonb;
        v_total_foreign numeric;
        v_line_base numeric;
        v_order_fx numeric;
      begin
        select o.currency, o.fx_rate, o.total, o.data
        into v_order
        from public.orders o
        where o.id = (v_rec.source_id)::uuid;

        if not found then continue; end if;

        v_data := coalesce(v_order.data, '{}'::jsonb);
        v_order_fx := coalesce(v_order.fx_rate, nullif((v_data->>'fxRate')::numeric, null), 1);
        if v_order_fx <= 0 then v_order_fx := 1; end if;

        v_total_foreign := coalesce(
          nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null),
          nullif((v_data->>'total')::numeric, null),
          coalesce(v_order.total, 0), 0
        );

        v_line_base := greatest(coalesce(v_rec.debit, 0), coalesce(v_rec.credit, 0));
        if v_line_base <= 0 or v_order_fx <= 0 then continue; end if;

        -- Recompute the correct foreign amount from the base
        update public.journal_lines
        set foreign_amount = round(v_line_base / v_order_fx, 2)
        where id = v_rec.jl_id;
        v_fixed_jl := v_fixed_jl + 1;
      end;
    exception when others then
      raise notice 'Error fixing order JL %: %', v_rec.jl_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 2 complete: total fixed %', v_fixed_jl;

  -- ====================================================================
  -- STEP 3: Rebuild party_ledger_entries
  -- ====================================================================
  raise notice 'Step 3: Rebuilding party_ledger_entries...';

  delete from public.party_ledger_entries;
  raise notice 'Cleared all party_ledger_entries';

  declare v_ple_count int;
  begin
    v_ple_count := coalesce(public.backfill_party_ledger_for_existing_entries(50000, null), 0);
    raise notice 'Rebuilt % party_ledger_entries', v_ple_count;
  end;

  -- ====================================================================
  -- STEP 4: Re-sync party_open_items foreign amounts from party_ledger_entries
  -- ====================================================================
  raise notice 'Step 4: Syncing party_open_items foreign amounts...';

  -- Insert missing open items
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
    upper(coalesce(ple.currency_code, v_base)),
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

  -- Update existing open items to sync foreign amounts
  update public.party_open_items poi
  set currency_code       = upper(coalesce(ple.currency_code, v_base)),
      foreign_amount      = ple.foreign_amount,
      open_foreign_amount = coalesce(ple.foreign_amount, poi.open_base_amount)
  from public.party_ledger_entries ple
  where poi.journal_line_id = ple.journal_line_id
    and (
      poi.foreign_amount is distinct from ple.foreign_amount
      or poi.open_foreign_amount is null
      or poi.open_foreign_amount = 0
      or poi.currency_code is distinct from upper(coalesce(ple.currency_code, v_base))
    );

  raise notice '=== ALL FIXES COMPLETE ===';

  -- Final verification
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
alter table public.party_ledger_entries enable trigger user;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    alter table public.party_open_items enable trigger user;
  end if;
end $$;

notify pgrst, 'reload schema';
