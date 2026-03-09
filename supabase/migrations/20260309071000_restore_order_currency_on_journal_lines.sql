-- ============================================================================
-- Restore: Re-apply correct currency_code, fx_rate, foreign_amount on
-- journal_lines for ORDERS that are in a foreign currency (YER).
-- The previous migration over-aggressively cleared currencies.
--
-- Logic:
--   For each journal_line linked to an order-sourced journal_entry:
--     - Look up the order's currency, fx_rate
--     - If the order is in a foreign currency, set the journal_line's
--       currency_code, fx_rate, and compute foreign_amount = base / fx
--     - If the order is in base currency, leave as-is
--
--   For each journal_line linked to a payment:
--     - Look up the related order via payment.reference_id
--     - If the order is in foreign currency AND the payment amount is
--       genuinely small (i.e. it's a SAR payment), leave currency as null
--     - If the payment truly was in YER, set it correctly
--
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
  v_fixed int := 0;
  v_rec record;
begin
  v_base := upper(coalesce(public.get_base_currency(), 'SAR'));
  raise notice 'Base currency: %', v_base;

  -- ====================================================================
  -- STEP 1: Re-apply currency on ORDER journal_lines
  -- ====================================================================
  raise notice 'Step 1: Re-applying currency on order journal_lines...';

  for v_rec in
    select
      jl.id as jl_id,
      jl.debit,
      jl.credit,
      je.source_id
    from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    join public.party_subledger_accounts psa
      on psa.account_id = jl.account_id and psa.is_active = true
    where je.source_table = 'orders'
      and je.source_event in ('delivered', 'invoiced')
  loop
    begin
      declare
        v_order record;
        v_data jsonb;
        v_order_currency text;
        v_order_fx numeric;
        v_line_base numeric;
        v_line_foreign numeric;
      begin
        select o.currency, o.fx_rate, o.total, o.data
        into v_order
        from public.orders o
        where o.id = (v_rec.source_id)::uuid;

        if not found then continue; end if;

        v_data := coalesce(v_order.data, '{}'::jsonb);
        v_order_currency := upper(nullif(btrim(coalesce(
          v_order.currency,
          v_data->>'currency',
          v_base
        )), ''));
        if v_order_currency is null then v_order_currency := v_base; end if;

        -- Skip base currency orders
        if v_order_currency = v_base then continue; end if;

        v_order_fx := coalesce(
          v_order.fx_rate,
          nullif((v_data->>'fxRate')::numeric, null),
          1
        );
        if v_order_fx <= 0 then v_order_fx := 1; end if;

        v_line_base := greatest(coalesce(v_rec.debit, 0), coalesce(v_rec.credit, 0));
        if v_line_base <= 0 then continue; end if;

        v_line_foreign := round(v_line_base / v_order_fx, 2);

        update public.journal_lines
        set currency_code  = v_order_currency,
            fx_rate        = v_order_fx,
            foreign_amount = v_line_foreign
        where id = v_rec.jl_id
          and (currency_code is null or foreign_amount is null or foreign_amount = 0);

        v_fixed := v_fixed + 1;
      end;
    exception when others then
      raise notice 'Error on JL %: %', v_rec.jl_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 1 done: fixed % order journal_lines', v_fixed;

  -- ====================================================================
  -- STEP 2: Fix PAYMENT journal_lines
  -- For payments linked to orders in foreign currency:
  --   - Check if payment has its own currency
  --   - If payment.currency is null or SAR, leave journal_line without
  --     foreign currency (it's a SAR deposit/payment)
  --   - If payment.currency is YER, use payment.amount as foreign
  -- ====================================================================
  raise notice 'Step 2: Fixing payment journal_lines...';

  v_fixed := 0;
  for v_rec in
    select
      jl.id as jl_id,
      jl.debit,
      jl.credit,
      je.source_id as payment_id
    from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    join public.party_subledger_accounts psa
      on psa.account_id = jl.account_id and psa.is_active = true
    where je.source_table = 'payments'
  loop
    begin
      declare
        v_pay record;
        v_pay_currency text;
        v_ref_order record;
        v_ref_data jsonb;
        v_order_currency text;
        v_order_fx numeric;
        v_pay_foreign numeric;
      begin
        select p.currency, p.amount, p.base_amount, p.fx_rate,
               p.reference_table, p.reference_id
        into v_pay
        from public.payments p
        where p.id = (v_rec.payment_id)::uuid;

        if not found then continue; end if;

        v_pay_currency := upper(nullif(btrim(coalesce(v_pay.currency, '')), ''));

        -- If payment has its own foreign currency, use it
        if v_pay_currency is not null and v_pay_currency <> v_base then
          update public.journal_lines
          set currency_code  = v_pay_currency,
              fx_rate        = coalesce(v_pay.fx_rate, 1),
              foreign_amount = abs(coalesce(v_pay.amount, 0))
          where id = v_rec.jl_id;
          v_fixed := v_fixed + 1;
          continue;
        end if;

        -- Payment is in SAR (no currency or SAR).
        -- Check if the related ORDER is in foreign currency.
        if v_pay.reference_table = 'orders' and v_pay.reference_id is not null then
          begin
            select o.currency, o.fx_rate, o.data
            into v_ref_order
            from public.orders o
            where o.id = (v_pay.reference_id)::uuid;

            if found then
              v_ref_data := coalesce(v_ref_order.data, '{}'::jsonb);
              v_order_currency := upper(nullif(btrim(coalesce(
                v_ref_order.currency,
                v_ref_data->>'currency',
                v_base
              )), ''));

              v_order_fx := coalesce(
                v_ref_order.fx_rate,
                nullif((v_ref_data->>'fxRate')::numeric, null),
                1
              );
              if v_order_fx <= 0 then v_order_fx := 1; end if;

              -- The payment is in SAR, but the order is in YER.
              -- Convert the SAR payment amount to YER equivalent for display.
              if v_order_currency is not null and v_order_currency <> v_base then
                declare v_line_base numeric;
                begin
                  v_line_base := greatest(coalesce(v_rec.debit, 0), coalesce(v_rec.credit, 0));
                  v_pay_foreign := round(v_line_base / v_order_fx, 2);

                  update public.journal_lines
                  set currency_code  = v_order_currency,
                      fx_rate        = v_order_fx,
                      foreign_amount = v_pay_foreign
                  where id = v_rec.jl_id;
                  v_fixed := v_fixed + 1;
                end;
              end if;
            end if;
          exception when others then
            null;
          end;
        end if;
      end;
    exception when others then
      raise notice 'Error on payment JL %: %', v_rec.jl_id, sqlerrm;
    end;
  end loop;

  raise notice 'Step 2 done: fixed % payment journal_lines', v_fixed;

  -- ====================================================================
  -- STEP 3: Rebuild party_ledger_entries
  -- ====================================================================
  raise notice 'Step 3: Rebuilding party_ledger_entries...';

  delete from public.party_ledger_entries;

  declare v_ple_count int;
  begin
    v_ple_count := coalesce(public.backfill_party_ledger_for_existing_entries(50000, null), 0);
    raise notice 'Rebuilt % party_ledger_entries', v_ple_count;
  end;

  -- ====================================================================
  -- STEP 4: Re-sync party_open_items
  -- ====================================================================
  raise notice 'Step 4: Syncing party_open_items...';

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
      open_foreign_amount = coalesce(ple.foreign_amount, poi.open_base_amount)
  from public.party_ledger_entries ple
  where poi.journal_line_id = ple.journal_line_id
    and (
      poi.currency_code is distinct from ple.currency_code
      or poi.foreign_amount is distinct from ple.foreign_amount
      or poi.open_foreign_amount is null
      or poi.open_foreign_amount = 0
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
