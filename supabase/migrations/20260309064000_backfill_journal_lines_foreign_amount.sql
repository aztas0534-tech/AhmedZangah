-- ============================================================================
-- Backfill: Repair ALL existing journal_lines for order deliveries that have
-- missing or zero foreign_amount when the order was in a foreign currency.
-- Then rebuild party_ledger_entries so running balances are correct.
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- Temporarily disable user triggers on journal_lines and party_ledger_entries
alter table public.journal_lines disable trigger user;
alter table public.party_ledger_entries disable trigger user;

do $$
declare
  v_base text;
  v_fixed_jl int := 0;
  v_fixed_ple int := 0;
  v_rec record;
  v_order record;
  v_data jsonb;
  v_order_currency text;
  v_order_fx numeric;
  v_total_foreign numeric;
  v_party_id uuid;
begin
  v_base := upper(coalesce(public.get_base_currency(), 'YER'));
  raise notice 'Base currency: %', v_base;

  -- ====================================================================
  -- STEP 1: Fix journal_lines.foreign_amount for order-sourced entries
  -- ====================================================================
  raise notice 'Step 1: Fixing journal_lines with missing foreign_amount...';

  for v_rec in
    select
      jl.id as jl_id,
      jl.journal_entry_id,
      jl.account_id,
      jl.debit,
      jl.credit,
      jl.currency_code as jl_currency,
      jl.fx_rate as jl_fx,
      jl.foreign_amount as jl_foreign,
      je.source_table,
      je.source_id,
      je.source_event
    from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    join public.party_subledger_accounts psa
      on psa.account_id = jl.account_id and psa.is_active = true
    where je.source_table = 'orders'
      and je.source_event in ('delivered', 'invoiced')
      and (
        jl.foreign_amount is null
        or jl.foreign_amount = 0
        or jl.currency_code is null
      )
  loop
    begin
      -- Look up the order
      select o.currency, o.fx_rate, o.total, o.data
      into v_order
      from public.orders o
      where o.id = (v_rec.source_id)::uuid;

      if not found then
        continue;
      end if;

      v_data := coalesce(v_order.data, '{}'::jsonb);

      -- Determine order currency
      v_order_currency := upper(nullif(btrim(coalesce(
        v_order.currency,
        v_data->>'currency',
        v_base
      )), ''));
      if v_order_currency is null then
        v_order_currency := v_base;
      end if;

      -- Skip if same as base currency (no foreign amount needed)
      if v_order_currency = v_base then
        continue;
      end if;

      -- Determine fx rate
      v_order_fx := coalesce(
        v_order.fx_rate,
        nullif((v_data->>'fxRate')::numeric, null),
        1
      );
      if v_order_fx is null or v_order_fx <= 0 then
        v_order_fx := 1;
      end if;

      -- Determine total in foreign currency
      v_total_foreign := coalesce(
        nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null),
        nullif((v_data->>'total')::numeric, null),
        coalesce(v_order.total, 0),
        0
      );

      -- If total_foreign is still 0, try to derive from base
      if v_total_foreign <= 0 and v_order_fx > 0 then
        v_total_foreign := round(greatest(coalesce(v_rec.debit, 0), coalesce(v_rec.credit, 0)) / v_order_fx, 2);
      end if;

      if v_total_foreign <= 0 then
        continue;
      end if;

      -- Calculate proportional foreign amount for this specific line
      -- The line's base amount is debit or credit
      declare
        v_line_base numeric;
        v_line_foreign numeric;
      begin
        v_line_base := greatest(coalesce(v_rec.debit, 0), coalesce(v_rec.credit, 0));
        if v_line_base <= 0 then
          continue;
        end if;
        v_line_foreign := round(v_line_base / v_order_fx, 2);

        update public.journal_lines
        set currency_code  = v_order_currency,
            fx_rate        = v_order_fx,
            foreign_amount = v_line_foreign
        where id = v_rec.jl_id;

        v_fixed_jl := v_fixed_jl + 1;
      end;

    exception when others then
      raise notice 'Error fixing JL %: %', v_rec.jl_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 1 complete: fixed % journal_lines', v_fixed_jl;

  -- ====================================================================
  -- STEP 2: Also fix journal_lines for payment-sourced entries
  -- ====================================================================
  raise notice 'Step 2: Fixing payment journal_lines with missing foreign_amount...';

  for v_rec in
    select
      jl.id as jl_id,
      jl.journal_entry_id,
      jl.account_id,
      jl.debit,
      jl.credit,
      je.source_table,
      je.source_id
    from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    join public.party_subledger_accounts psa
      on psa.account_id = jl.account_id and psa.is_active = true
    where je.source_table = 'payments'
      and (
        jl.foreign_amount is null
        or jl.foreign_amount = 0
        or jl.currency_code is null
      )
  loop
    begin
      declare
        v_pay record;
        v_pay_currency text;
        v_pay_fx numeric;
        v_pay_foreign numeric;
      begin
        select p.currency, p.fx_rate, p.amount
        into v_pay
        from public.payments p
        where p.id = (v_rec.source_id)::uuid;

        if not found then continue; end if;

        v_pay_currency := upper(nullif(btrim(coalesce(v_pay.currency, '')), ''));
        if v_pay_currency is null or v_pay_currency = v_base then
          continue;
        end if;

        v_pay_fx := coalesce(v_pay.fx_rate, 1);
        v_pay_foreign := abs(coalesce(v_pay.amount, 0));

        if v_pay_foreign <= 0 then continue; end if;

        update public.journal_lines
        set currency_code  = v_pay_currency,
            fx_rate        = v_pay_fx,
            foreign_amount = v_pay_foreign
        where id = v_rec.jl_id;

        v_fixed_jl := v_fixed_jl + 1;
      end;
    exception when others then
      raise notice 'Error fixing payment JL %: %', v_rec.jl_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 2 complete: total fixed journal_lines now %', v_fixed_jl;

  -- ====================================================================
  -- STEP 3: Delete all party_ledger_entries and rebuild from scratch
  --         so that foreign_amount and running_balance are correct
  -- ====================================================================
  raise notice 'Step 3: Rebuilding party_ledger_entries...';

  delete from public.party_ledger_entries;
  raise notice 'Cleared all party_ledger_entries';

  -- Run the existing backfill function
  v_fixed_ple := coalesce(public.backfill_party_ledger_for_existing_entries(50000, null), 0);
  raise notice 'Rebuilt % party_ledger_entries', v_fixed_ple;

  -- ====================================================================
  -- STEP 4: Rebuild party_open_items for each party
  -- ====================================================================
  raise notice 'Step 4: Rebuilding party_open_items...';

  for v_rec in
    select id, name from public.financial_parties where is_active = true
  loop
    begin
      declare v_result jsonb;
      begin
        v_result := public.backfill_party_open_items_for_party(v_rec.id, 50000);
        raise notice 'Party "%": ledger=%, open=%',
          v_rec.name,
          coalesce((v_result->>'ledgerBackfilled')::int, 0),
          coalesce((v_result->>'openItemsCreated')::int, 0);
      end;
    exception when others then
      raise notice 'Party "%" FAILED: %', v_rec.name, sqlerrm;
    end;
  end loop;

  raise notice '=== BACKFILL COMPLETE ===';
  raise notice 'Total journal_lines fixed: %', v_fixed_jl;
  raise notice 'Total party_ledger_entries rebuilt: %', v_fixed_ple;

  -- Final counts
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

notify pgrst, 'reload schema';
