-- ============================================================================
-- ROOT CAUSE FIX: Payment records linked to foreign-currency orders have
-- base_amount = amount (no FX conversion). This causes journal_lines to
-- have inflated debit/credit in the wrong currency.
--
-- The fix:
--   1. Fix payments.base_amount for YER-order payments (amount × fx_rate)
--   2. Fix journal_lines debit/credit for payment entries
--   3. Fix journal_lines debit/credit for order delivery entries
--      (deposits_paid_base was inflated, reducing AR incorrectly)
--   4. Rebuild party_ledger_entries and party_open_items
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
  v_fixed_payments int := 0;
  v_fixed_jl int := 0;
  v_rec record;
begin
  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));
  raise notice 'Base currency: %', v_base;

  -- ====================================================================
  -- STEP 1: Diagnose and fix payments.base_amount
  -- For payments linked to orders in foreign currency where
  -- base_amount ≈ amount (meaning no FX was applied)
  -- ====================================================================
  raise notice 'Step 1: Diagnosing payments with wrong base_amount...';

  for v_rec in
    select
      p.id as payment_id,
      p.amount as pay_amount,
      p.base_amount as pay_base,
      p.currency as pay_currency,
      p.fx_rate as pay_fx,
      p.reference_id,
      o.currency as order_currency,
      o.fx_rate as order_fx,
      o.total as order_total,
      o.data as order_data
    from public.payments p
    join public.orders o on o.id = (p.reference_id)::uuid
    where p.reference_table = 'orders'
      and p.reference_id is not null
  loop
    begin
      declare
        v_order_currency text;
        v_order_fx numeric;
        v_expected_base numeric;
        v_data jsonb;
      begin
        v_data := coalesce(v_rec.order_data, '{}'::jsonb);
        v_order_currency := upper(nullif(btrim(coalesce(
          v_rec.order_currency,
          v_data->>'currency',
          v_base
        )), ''));
        if v_order_currency is null then v_order_currency := v_base; end if;

        -- Skip base currency orders
        if v_order_currency = v_base then continue; end if;

        v_order_fx := coalesce(
          v_rec.order_fx,
          nullif((v_data->>'fxRate')::numeric, null),
          1
        );
        if v_order_fx is null or v_order_fx <= 0 then v_order_fx := 1; end if;

        -- Expected base = amount × fx_rate
        v_expected_base := round(v_rec.pay_amount * v_order_fx, 2);

        -- Check if base_amount is wrong (≈ amount instead of amount × fx)
        if abs(coalesce(v_rec.pay_base, 0) - v_rec.pay_amount) < 1.0
           and abs(v_expected_base - v_rec.pay_amount) > 1.0 then
          raise notice 'Payment %: amount=% base_amount=% → should be % (fx=%)',
            v_rec.payment_id, v_rec.pay_amount, v_rec.pay_base, v_expected_base, v_order_fx;

          update public.payments
          set base_amount = v_expected_base,
              currency = coalesce(nullif(btrim(currency), ''), v_order_currency),
              fx_rate = coalesce(fx_rate, v_order_fx)
          where id = v_rec.payment_id;

          v_fixed_payments := v_fixed_payments + 1;
        end if;
      end;
    exception when others then
      raise notice 'Error on payment %: %', v_rec.payment_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 1 done: fixed % payments', v_fixed_payments;

  -- ====================================================================
  -- STEP 2: Fix journal_lines for payments
  -- Set debit/credit to the correct base_amount, and foreign_amount
  -- to the original payment amount in foreign currency
  -- ====================================================================
  raise notice 'Step 2: Fixing payment journal_lines...';

  for v_rec in
    select
      jl.id as jl_id,
      jl.debit,
      jl.credit,
      je.source_id,
      p.amount as pay_amount,
      p.base_amount as pay_base,
      p.currency as pay_currency,
      p.fx_rate as pay_fx,
      p.reference_id,
      o.currency as order_currency,
      o.fx_rate as order_fx,
      o.data as order_data
    from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    join public.payments p on p.id = (je.source_id)::uuid
    left join public.orders o on o.id = (p.reference_id)::uuid
    where je.source_table = 'payments'
  loop
    begin
      declare
        v_order_currency text;
        v_order_fx numeric;
        v_correct_base numeric;
        v_correct_foreign numeric;
        v_data jsonb;
        v_old_amount numeric;
      begin
        v_data := coalesce(v_rec.order_data, '{}'::jsonb);
        v_order_currency := upper(nullif(btrim(coalesce(
          v_rec.order_currency,
          v_data->>'currency',
          v_base
        )), ''));
        if v_order_currency is null then v_order_currency := v_base; end if;

        -- Skip base currency orders
        if v_order_currency = v_base then continue; end if;

        v_order_fx := coalesce(
          v_rec.order_fx,
          nullif((v_data->>'fxRate')::numeric, null),
          1
        );
        if v_order_fx is null or v_order_fx <= 0 then v_order_fx := 1; end if;

        -- The payment.amount is in foreign currency (YER)
        -- The correct base = amount × fx_rate
        v_correct_base := round(v_rec.pay_amount * v_order_fx, 2);
        v_correct_foreign := v_rec.pay_amount;

        v_old_amount := greatest(coalesce(v_rec.debit, 0), coalesce(v_rec.credit, 0));

        -- Only fix if the current debit/credit is wrong
        if abs(v_old_amount - v_correct_base) > 0.5 then
          if coalesce(v_rec.debit, 0) > 0 then
            update public.journal_lines
            set debit = v_correct_base,
                currency_code = v_order_currency,
                fx_rate = v_order_fx,
                foreign_amount = v_correct_foreign
            where id = v_rec.jl_id;
          else
            update public.journal_lines
            set credit = v_correct_base,
                currency_code = v_order_currency,
                fx_rate = v_order_fx,
                foreign_amount = v_correct_foreign
            where id = v_rec.jl_id;
          end if;
          v_fixed_jl := v_fixed_jl + 1;
          raise notice 'Fixed JL %: % → % (%)', v_rec.jl_id, v_old_amount, v_correct_base, v_order_currency;
        else
          -- Just ensure foreign amount is correct
          update public.journal_lines
          set currency_code = v_order_currency,
              fx_rate = v_order_fx,
              foreign_amount = v_correct_foreign
          where id = v_rec.jl_id
            and (currency_code is null or foreign_amount is null or foreign_amount = 0);
        end if;
      end;
    exception when others then
      raise notice 'Error on JL %: %', v_rec.jl_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 2 done: fixed % payment journal_lines', v_fixed_jl;

  -- ====================================================================
  -- STEP 3: Re-post order delivery entries
  -- The original post_order_delivery used deposits_paid_base from payments.
  -- Since payments.base_amount was wrong, the AR vs deposits split was wrong.
  -- We need to void and re-post these delivery entries.
  --
  -- Instead, we fix the journal_lines directly:
  --   - AR line: debit should be (total_base - deposits_base_correct)
  --   - Deposits line: debit should be deposits_base_correct
  -- ====================================================================
  raise notice 'Step 3: Fixing order delivery journal_lines...';

  v_fixed_jl := 0;

  for v_rec in
    select
      je.id as je_id,
      je.source_id as order_id,
      o.currency as order_currency,
      o.fx_rate as order_fx,
      o.total as order_total,
      o.base_total as order_base_total,
      o.data as order_data
    from public.journal_entries je
    join public.orders o on o.id = (je.source_id)::uuid
    where je.source_table = 'orders'
      and je.source_event in ('delivered', 'invoiced')
  loop
    begin
      declare
        v_data jsonb;
        v_order_currency text;
        v_order_fx numeric;
        v_total_base numeric;
        v_total_foreign numeric;
        v_deposits_base numeric;
        v_deposits_foreign numeric;
        v_ar_base numeric;
        v_ar_foreign numeric;
        v_delivery_base numeric;
        v_tax_base numeric;
        v_items_revenue_base numeric;
        v_ar_account uuid;
        v_deposits_account uuid;
        v_sales_account uuid;
        v_accounts jsonb;
      begin
        v_data := coalesce(v_rec.order_data, '{}'::jsonb);
        v_order_currency := upper(nullif(btrim(coalesce(
          v_rec.order_currency,
          v_data->>'currency',
          v_base
        )), ''));
        if v_order_currency is null or v_order_currency = v_base then continue; end if;

        v_order_fx := coalesce(
          v_rec.order_fx,
          nullif((v_data->>'fxRate')::numeric, null),
          1
        );
        if v_order_fx <= 0 then v_order_fx := 1; end if;

        -- Total base
        if v_rec.order_base_total is not null then
          v_total_base := v_rec.order_base_total;
        else
          v_total_foreign := coalesce(
            nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null),
            nullif((v_data->>'total')::numeric, null),
            coalesce(v_rec.order_total, 0), 0
          );
          v_total_base := round(v_total_foreign * v_order_fx, 2);
        end if;

        v_total_foreign := coalesce(
          nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null),
          nullif((v_data->>'total')::numeric, null),
          coalesce(v_rec.order_total, 0), 0
        );
        if v_total_foreign <= 0 and v_order_fx > 0 then
          v_total_foreign := round(v_total_base / v_order_fx, 2);
        end if;

        -- SUM correctly converted deposit base amounts
        select coalesce(sum(round(p.amount * v_order_fx, 2)), 0)
        into v_deposits_base
        from public.payments p
        where p.reference_table = 'orders'
          and p.reference_id = v_rec.order_id::text
          and p.direction = 'in';

        select coalesce(sum(p.amount), 0)
        into v_deposits_foreign
        from public.payments p
        where p.reference_table = 'orders'
          and p.reference_id = v_rec.order_id::text
          and p.direction = 'in';

        v_deposits_base := least(v_total_base, greatest(0, v_deposits_base));
        v_deposits_foreign := least(v_total_foreign, greatest(0, v_deposits_foreign));
        v_ar_base := greatest(0, v_total_base - v_deposits_base);
        v_ar_foreign := greatest(0, v_total_foreign - v_deposits_foreign);

        -- Breakdown
        v_delivery_base := coalesce(
          nullif((v_data->'invoiceSnapshot'->>'deliveryFee')::numeric, null),
          nullif((v_data->>'deliveryFee')::numeric, null), 0
        ) * v_order_fx;
        v_tax_base := coalesce(
          nullif((v_data->'invoiceSnapshot'->>'taxAmount')::numeric, null),
          nullif((v_data->>'taxAmount')::numeric, null), 0
        ) * v_order_fx;
        v_tax_base := least(greatest(0, v_tax_base), v_total_base);
        v_delivery_base := least(greatest(0, v_delivery_base), v_total_base - v_tax_base);
        v_items_revenue_base := greatest(0, v_total_base - v_delivery_base - v_tax_base);

        -- Get account IDs
        select s.data->'accounting_accounts' into v_accounts
        from public.app_settings s where s.id = 'singleton';

        v_ar_account := public.get_account_id_by_code(coalesce(v_accounts->>'ar','1200'));
        v_deposits_account := public.get_account_id_by_code(coalesce(v_accounts->>'deposits','2050'));
        v_sales_account := public.get_account_id_by_code(coalesce(v_accounts->>'sales','4010'));

        -- Update AR line
        if v_ar_account is not null then
          update public.journal_lines
          set debit = v_ar_base,
              currency_code = v_order_currency,
              fx_rate = v_order_fx,
              foreign_amount = v_ar_foreign
          where journal_entry_id = v_rec.je_id
            and account_id = v_ar_account
            and coalesce(debit, 0) > 0;
        end if;

        -- Update deposits line
        if v_deposits_account is not null and v_deposits_base > 0 then
          update public.journal_lines
          set debit = v_deposits_base,
              currency_code = v_order_currency,
              fx_rate = v_order_fx,
              foreign_amount = v_deposits_foreign
          where journal_entry_id = v_rec.je_id
            and account_id = v_deposits_account
            and coalesce(debit, 0) > 0;
        end if;

        -- Update sales revenue line
        if v_sales_account is not null then
          update public.journal_lines
          set credit = v_items_revenue_base
          where journal_entry_id = v_rec.je_id
            and account_id = v_sales_account
            and coalesce(credit, 0) > 0;
        end if;

        v_fixed_jl := v_fixed_jl + 1;
      end;
    exception when others then
      raise notice 'Error on JE %: %', v_rec.je_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 3 done: fixed % order delivery entries', v_fixed_jl;

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

  raise notice '=== ALL FIXES COMPLETE ===';

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
