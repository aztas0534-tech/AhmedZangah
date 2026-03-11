-- ============================================================================
-- Fix: post_order_delivery was not writing currency_code / fx_rate /
-- foreign_amount on journal_lines, causing the trigger fallback
-- (trg_set_journal_line_party) to read orders.total which can be 0/null
-- while the real total lives in data->'invoiceSnapshot'->'total'.
--
-- This migration:
--   1. Re-creates post_order_delivery so it explicitly writes foreign amounts.
--   2. Updates trg_set_journal_line_party to fall back to invoiceSnapshot.
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- ============================================================================
-- 1. Fix post_order_delivery – write foreign amounts explicitly
-- ============================================================================

create or replace function public.post_order_delivery(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order        record;
  v_entry_id     uuid;
  v_total_base   numeric := 0;
  v_ar           uuid;
  v_deposits     uuid;
  v_sales        uuid;
  v_delivery_income uuid;
  v_vat_payable  uuid;
  v_delivered_at timestamptz;
  v_deposits_paid_base numeric := 0;
  v_ar_amount_base     numeric := 0;
  v_delivery_base      numeric := 0;
  v_tax_base           numeric := 0;
  v_items_revenue_base numeric := 0;
  v_accounts     jsonb;
  v_base         text;
  v_currency     text;
  v_fx           numeric;
  v_data         jsonb;
  -- ── NEW: foreign-amount tracking ──
  v_is_foreign          boolean := false;
  v_total_foreign       numeric := 0;
  v_ar_foreign          numeric := 0;
  v_deposits_foreign    numeric := 0;
  v_deposits_paid_foreign numeric := 0;
begin
  -- allow service_role to bypass staff check
  if auth.role() <> 'service_role' then
    perform public._require_staff('accounting.post');
  end if;

  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

  -- idempotency: skip if already posted
  if exists (
    select 1
    from public.journal_entries je
    where je.source_table = 'orders'
      and je.source_id    = p_order_id::text
      and je.source_event = 'delivered'
    limit 1
  ) then
    return;
  end if;

  select o.*
  into v_order
  from public.orders o
  where o.id = p_order_id;
  if not found then
    raise exception 'order not found';
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'YER'));
  v_data := coalesce(v_order.data, '{}'::jsonb);

  v_currency := upper(nullif(btrim(coalesce(
    v_order.currency,
    v_data->>'currency',
    v_base
  )), ''));
  if v_currency is null then
    v_currency := v_base;
  end if;

  v_fx := coalesce(v_order.fx_rate,
                    nullif((v_data->>'fxRate')::numeric, null),
                    1);
  if v_fx is null or v_fx <= 0 then
    v_fx := 1;
  end if;

  v_is_foreign := (v_currency <> v_base);

  -- ── total in base currency ──
  if v_order.base_total is not null then
    v_total_base := coalesce(v_order.base_total, 0);
  else
    v_total_base := coalesce(
      nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null),
      nullif((v_data->>'total')::numeric, null),
      coalesce(v_order.total, 0),
      0
    ) * v_fx;
  end if;
  if coalesce(v_total_base, 0) <= 0 then
    return;
  end if;

  -- ── total in foreign (transaction) currency ──
  v_total_foreign := coalesce(
    nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null),
    nullif((v_data->>'total')::numeric, null),
    coalesce(v_order.total, 0),
    0
  );
  -- safety: if foreign total is 0 but we have base, derive it
  if v_is_foreign and v_total_foreign <= 0 and v_fx > 0 then
    v_total_foreign := round(v_total_base / v_fx, 2);
  end if;

  -- ── account lookup ──
  select s.data->'accounting_accounts'
  into v_accounts
  from public.app_settings s
  where s.id = 'singleton';

  v_ar              := public.get_account_id_by_code(coalesce(v_accounts->>'ar','1200'));
  if v_ar is null then raise exception 'Account AR (1200) not found'; end if;
  v_deposits        := public.get_account_id_by_code(coalesce(v_accounts->>'deposits','2050'));
  if v_deposits is null then raise exception 'Account Deposits (2050) not found'; end if;
  v_sales           := public.get_account_id_by_code(coalesce(v_accounts->>'sales','4010'));
  if v_sales is null then raise exception 'Account Sales (4010) not found'; end if;
  v_delivery_income := public.get_account_id_by_code(coalesce(v_accounts->>'delivery_income','4020'));
  v_vat_payable     := public.get_account_id_by_code(coalesce(v_accounts->>'vat_payable','2020'));

  -- ── delivered timestamp ──
  v_delivered_at := public.order_delivered_at(p_order_id);
  if v_delivered_at is null then
    v_delivered_at := coalesce(v_order.updated_at, now());
  end if;

  -- ── delivery / tax breakdown (base) ──
  v_delivery_base := coalesce(
    nullif((v_data->'invoiceSnapshot'->>'deliveryFee')::numeric, null),
    nullif((v_data->>'deliveryFee')::numeric, null),
    coalesce(v_order.delivery_fee, 0), 0
  ) * v_fx;

  v_tax_base := coalesce(
    nullif((v_data->'invoiceSnapshot'->>'taxAmount')::numeric, null),
    nullif((v_data->>'taxAmount')::numeric, null),
    coalesce(v_order.tax, 0), 0
  ) * v_fx;

  v_tax_base      := least(greatest(0, v_tax_base), v_total_base);
  v_delivery_base := least(greatest(0, v_delivery_base), v_total_base - v_tax_base);
  v_items_revenue_base := greatest(0, v_total_base - v_delivery_base - v_tax_base);

  -- ── deposits already paid (base) ──
  begin
    select coalesce(sum(coalesce(p.base_amount, 0)), 0)
    into v_deposits_paid_base
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id   = p_order_id::text
      and p.direction      = 'in'
      and p.status         = 'paid';
  exception when others then
    v_deposits_paid_base := 0;
  end;

  -- ── deposits already paid (foreign) ──
  begin
    select coalesce(sum(coalesce(p.amount, 0)), 0)
    into v_deposits_paid_foreign
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id   = p_order_id::text
      and p.direction      = 'in'
      and p.status         = 'paid';
  exception when others then
    v_deposits_paid_foreign := 0;
  end;

  v_deposits_paid_base := least(v_total_base, greatest(0, v_deposits_paid_base));
  v_ar_amount_base     := greatest(0, v_total_base - v_deposits_paid_base);

  -- ── foreign proportional amounts ──
  if v_is_foreign and v_fx > 0 then
    v_deposits_paid_foreign := least(v_total_foreign, greatest(0, v_deposits_paid_foreign));
    v_ar_foreign            := greatest(0, v_total_foreign - v_deposits_paid_foreign);
    v_deposits_foreign      := v_deposits_paid_foreign;
  else
    v_ar_foreign       := 0;
    v_deposits_foreign := 0;
  end if;

  -- ── journal entry header ──
  begin
    insert into public.journal_entries (
      entry_date, memo, source_table, source_id, source_event,
      status, currency_code, fx_rate
    ) values (
      v_delivered_at,
      'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
      'orders',
      p_order_id::text,
      'delivered',
      'posted',
      v_currency,
      v_fx
    )
    returning id into v_entry_id;
  exception when undefined_column then
    begin
      insert into public.journal_entries (
        entry_date, memo, source_table, source_id, source_event,
        status, currency, fx_rate
      ) values (
        v_delivered_at,
        'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
        'orders',
        p_order_id::text,
        'delivered',
        'posted',
        v_currency,
        v_fx
      )
      returning id into v_entry_id;
    exception when undefined_column then
      insert into public.journal_entries (
        entry_date, memo, source_table, source_id, source_event, status
      ) values (
        v_delivered_at,
        'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
        'orders',
        p_order_id::text,
        'delivered',
        'posted'
      )
      returning id into v_entry_id;
    end;
  end;

  -- ── AR line (with explicit foreign amount) ──
  if v_ar_amount_base > 0 then
    insert into public.journal_lines(
      journal_entry_id, account_id, debit, credit, line_memo,
      currency_code, fx_rate, foreign_amount
    ) values (
      v_entry_id, v_ar, v_ar_amount_base, 0, 'استحقاق آجل',
      case when v_is_foreign then v_currency else null end,
      case when v_is_foreign then v_fx       else null end,
      case when v_is_foreign then v_ar_foreign else null end
    );
  end if;

  -- ── Deposits line (with explicit foreign amount) ──
  if v_deposits_paid_base > 0 then
    insert into public.journal_lines(
      journal_entry_id, account_id, debit, credit, line_memo,
      currency_code, fx_rate, foreign_amount
    ) values (
      v_entry_id, v_deposits, v_deposits_paid_base, 0, 'تسوية دفعات مقدمة/نقدية',
      case when v_is_foreign then v_currency       else null end,
      case when v_is_foreign then v_fx              else null end,
      case when v_is_foreign then v_deposits_foreign else null end
    );
  end if;

  -- ── Revenue lines (base only, not party-tracked) ──
  if v_items_revenue_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_sales, 0, v_items_revenue_base, 'إيرادات مبيعات');
  end if;

  if v_delivery_base > 0 then
    if v_delivery_income is null then raise exception 'Account Delivery Income (4020) not found'; end if;
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_delivery_income, 0, v_delivery_base, 'إيرادات توصيل');
  end if;

  if v_tax_base > 0 then
    if v_vat_payable is null then raise exception 'Account VAT Payable (2020) not found'; end if;
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_vat_payable, 0, v_tax_base, 'ضريبة القيمة المضافة');
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
exception when others then
  raise exception 'POST_DELIVERY_ERROR: %', SQLERRM;
end;
$$;


-- ============================================================================
-- 2. Fix trg_set_journal_line_party – read from invoiceSnapshot / data
--    when orders.total is null or 0
-- ============================================================================

create or replace function public.trg_set_journal_line_party()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source_table text;
  v_source_id    text;
  v_party_id     uuid;
  v_is_party_account boolean := false;
  v_base         text;
  v_order        record;
  v_po           record;
  v_order_data   jsonb;
  v_foreign_amt  numeric;
begin
  -- If party already set, skip
  if new.party_id is not null then
    return new;
  end if;

  select je.source_table, je.source_id
  into v_source_table, v_source_id
  from public.journal_entries je
  where je.id = new.journal_entry_id;

  v_party_id := public._resolve_party_for_entry(
    coalesce(v_source_table, ''),
    coalesce(v_source_id, '')
  );
  new.party_id := v_party_id;

  -- Check if this account is a party sub-ledger account
  select exists(
    select 1
    from public.party_subledger_accounts psa
    where psa.account_id = new.account_id
      and psa.is_active = true
    limit 1
  ) into v_is_party_account;

  -- Only fill currency if not already set AND it's a party account
  if v_is_party_account and new.currency_code is null then
    v_base := public.get_base_currency();

    if v_source_table = 'payments' then
      begin
        select p.currency, p.fx_rate, p.amount
        into v_order
        from public.payments p
        where p.id = (v_source_id)::uuid;
        if v_order.currency is not null and upper(v_order.currency) <> upper(v_base) then
          new.currency_code  := upper(v_order.currency);
          new.fx_rate        := coalesce(v_order.fx_rate, 1);
          new.foreign_amount := abs(coalesce(v_order.amount, 0));
        end if;
      exception when others then
        null;
      end;

    elsif v_source_table = 'orders' then
      begin
        select o.currency, o.fx_rate, o.total, o.data
        into v_order
        from public.orders o
        where o.id = (v_source_id)::uuid;

        if v_order.currency is not null and upper(v_order.currency) <> upper(v_base) then
          new.currency_code := upper(v_order.currency);
          new.fx_rate       := coalesce(v_order.fx_rate, 1);

          -- ── FIX: prefer invoiceSnapshot.total or data.total over orders.total ──
          v_order_data := coalesce(v_order.data, '{}'::jsonb);
          v_foreign_amt := coalesce(
            nullif((v_order_data->'invoiceSnapshot'->>'total')::numeric, null),
            nullif((v_order_data->>'total')::numeric, null),
            coalesce(v_order.total, 0),
            0
          );
          new.foreign_amount := abs(v_foreign_amt);
        end if;
      exception when others then
        null;
      end;

    elsif v_source_table = 'purchase_orders' then
      begin
        select po.currency, po.fx_rate, po.total_amount
        into v_po
        from public.purchase_orders po
        where po.id = (v_source_id)::uuid;
        if v_po.currency is not null and upper(v_po.currency) <> upper(v_base) then
          new.currency_code  := upper(v_po.currency);
          new.fx_rate        := coalesce(v_po.fx_rate, 1);
          new.foreign_amount := abs(coalesce(v_po.total_amount, 0));
        end if;
      exception when others then
        null;
      end;

    elsif v_source_table = 'inventory_movements' then
      begin
        select po.currency, po.fx_rate, po.total_amount
        into v_po
        from public.inventory_movements im
        left join public.batches b on b.id = im.batch_id
        left join public.purchase_receipts pr on pr.id = b.receipt_id
        left join public.purchase_orders po on po.id = pr.purchase_order_id
        where im.id = (v_source_id)::uuid;
        if v_po.currency is not null and upper(v_po.currency) <> upper(v_base) then
          new.currency_code  := upper(v_po.currency);
          new.fx_rate        := coalesce(v_po.fx_rate, 1);
          new.foreign_amount := abs(coalesce(v_po.total_amount, 0));
        end if;
      exception when others then
        null;
      end;
    end if;
  end if;

  return new;
end;
$$;

-- Re-create trigger (idempotent)
do $$
begin
  if to_regclass('public.journal_lines') is not null then
    drop trigger if exists trg_set_journal_line_party on public.journal_lines;
    create trigger trg_set_journal_line_party
    before insert on public.journal_lines
    for each row execute function public.trg_set_journal_line_party();
  end if;
end $$;

notify pgrst, 'reload schema';
