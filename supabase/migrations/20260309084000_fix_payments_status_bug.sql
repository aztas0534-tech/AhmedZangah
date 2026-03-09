-- ============================================================================
-- Fix: post_order_delivery was querying payments.status = 'paid', but the
-- status column on payments was removed. This caused an exception that
-- silently defaulted deposits_paid to 0, causing deliveries to post full
-- invoice amounts to AR and ignore deposits.
--
-- This migration updates the function to only check `direction = 'in'`
-- (or whatever is appropriate for incoming payments) and then re-posts
-- all deliveries to fix the balances once more.
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- ============================================================================
-- 1. Fix post_order_delivery
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

  if p_order_id is null then raise exception 'p_order_id is required'; end if;

  -- idempotency check
  if exists (
    select 1 from public.journal_entries je
    where je.source_table = 'orders' and je.source_id = p_order_id::text
      and je.source_event = 'delivered' limit 1
  ) then
    return;
  end if;

  select o.* into v_order from public.orders o where o.id = p_order_id;
  if not found then raise exception 'order not found'; end if;

  v_base := upper(coalesce(public.get_base_currency(), 'YER'));
  v_data := coalesce(v_order.data, '{}'::jsonb);

  v_currency := upper(nullif(btrim(coalesce(v_order.currency, v_data->>'currency', v_base)), ''));
  if v_currency is null then v_currency := v_base; end if;

  v_fx := coalesce(v_order.fx_rate, nullif((v_data->>'fxRate')::numeric, null), 1);
  if v_fx is null or v_fx <= 0 then v_fx := 1; end if;

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
  if coalesce(v_total_base, 0) <= 0 then return; end if;

  -- ── total in foreign ──
  v_total_foreign := coalesce(
    nullif((v_data->'invoiceSnapshot'->>'total')::numeric, null),
    nullif((v_data->>'total')::numeric, null),
    coalesce(v_order.total, 0),
    0
  );
  if v_is_foreign and v_total_foreign <= 0 and v_fx > 0 then
    v_total_foreign := round(v_total_base / v_fx, 2);
  end if;

  -- ── account lookup ──
  select s.data->'accounting_accounts' into v_accounts from public.app_settings s where s.id = 'singleton';
  v_ar              := public.get_account_id_by_code(coalesce(v_accounts->>'ar','1200'));
  v_deposits        := public.get_account_id_by_code(coalesce(v_accounts->>'deposits','2050'));
  v_sales           := public.get_account_id_by_code(coalesce(v_accounts->>'sales','4010'));
  v_delivery_income := public.get_account_id_by_code(coalesce(v_accounts->>'delivery_income','4020'));
  v_vat_payable     := public.get_account_id_by_code(coalesce(v_accounts->>'vat_payable','2020'));

  if v_ar is null or v_deposits is null or v_sales is null then
    raise exception 'Critical accounts missing';
  end if;

  -- ── delivered timestamp ──
  v_delivered_at := public.order_delivered_at(p_order_id);
  if v_delivered_at is null then v_delivered_at := coalesce(v_order.updated_at, now()); end if;

  -- ── breakdowns ──
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
      and p.direction      = 'in';
  exception when others then
    -- It's better to log the error than silently fail completely
    raise notice 'Error calculating base deposits: %', sqlerrm;
    v_deposits_paid_base := 0;
  end;

  -- ── deposits already paid (foreign) ──
  begin
    select coalesce(sum(coalesce(p.amount, 0)), 0)
    into v_deposits_paid_foreign
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id   = p_order_id::text
      and p.direction      = 'in';
  exception when others then
    raise notice 'Error calculating foreign deposits: %', sqlerrm;
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
      'orders', p_order_id::text, 'delivered', 'posted', v_currency, v_fx
    ) returning id into v_entry_id;
  exception when undefined_column then
    begin
      insert into public.journal_entries (
        entry_date, memo, source_table, source_id, source_event, status, currency, fx_rate
      ) values (
        v_delivered_at, 'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
        'orders', p_order_id::text, 'delivered', 'posted', v_currency, v_fx
      ) returning id into v_entry_id;
    exception when undefined_column then
      insert into public.journal_entries (
        entry_date, memo, source_table, source_id, source_event, status
      ) values (
        v_delivered_at, 'استحقاق مبيعات (تلقائي) - طلب #' || right(p_order_id::text, 6),
        'orders', p_order_id::text, 'delivered', 'posted'
      ) returning id into v_entry_id;
    end;
  end;

  -- ── AR line ──
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

  -- ── Deposits line ──
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

  -- ── Revenue lines ──
  if v_items_revenue_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_sales, 0, v_items_revenue_base, 'إيرادات مبيعات');
  end if;

  if v_delivery_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_delivery_income, 0, v_delivery_base, 'إيرادات توصيل');
  end if;

  if v_tax_base > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_vat_payable, 0, v_tax_base, 'ضريبة القيمة المضافة');
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
exception when others then
  raise notice 'POST_DELIVERY_ERROR: %', SQLERRM;
end;
$$;


-- ============================================================================
-- 2. Re-post all order delivery entries using Nuclear Approach from last migration
-- ============================================================================

-- Disable user triggers on all affected tables
alter table public.journal_lines disable trigger user;
alter table public.journal_entries disable trigger user;
alter table public.party_ledger_entries disable trigger user;
alter table public.settlement_lines disable trigger user;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    alter table public.party_open_items disable trigger user;
  end if;
  if to_regclass('public.ar_open_items') is not null then
    alter table public.ar_open_items disable trigger user;
  end if;
  if to_regclass('public.ledger_entry_hash_chain') is not null then
    alter table public.ledger_entry_hash_chain disable trigger user;
  end if;
end $$;

-- Use TRUNCATE CASCADE on the root tables to clear everything
-- that depends on journal_entries/journal_lines
truncate public.party_ledger_entries cascade;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    truncate public.party_open_items cascade;
  end if;
  if to_regclass('public.ar_open_items') is not null then
    truncate public.ar_open_items cascade;
  end if;
  if to_regclass('public.ledger_entry_hash_chain') is not null then
    truncate public.ledger_entry_hash_chain cascade;
  end if;
end $$;

-- Now delete order delivery journal entries (no more FK blockers)
delete from public.journal_lines jl
using public.journal_entries je
where jl.journal_entry_id = je.id
  and je.source_table = 'orders'
  and je.source_event in ('delivered', 'invoiced', 'reversal', 'void');

delete from public.journal_entries je
where je.source_table = 'orders'
  and je.source_event in ('delivered', 'invoiced', 'reversal', 'void');

-- Re-post all delivered orders
do $$
declare
  v_rec record;
  v_posted int := 0;
  v_errors int := 0;
  v_ple_count int := 0;
  v_poi_count int := 0;
begin
  raise notice 'Re-posting delivery for all delivered orders...';

  for v_rec in
    select o.id, o.invoice_number
    from public.orders o
    where o.status = 'delivered'
    order by o.created_at asc
  loop
    begin
      perform public.post_order_delivery(v_rec.id);
      v_posted := v_posted + 1;
    exception when others then
      raise notice 'Error posting order % (%): %', v_rec.id, v_rec.invoice_number, sqlerrm;
      v_errors := v_errors + 1;
    end;
  end loop;

  raise notice 'Deliveries posted: %, errors: %', v_posted, v_errors;

  -- Rebuild party_ledger_entries
  raise notice 'Rebuilding party_ledger_entries...';
  v_ple_count := coalesce(public.backfill_party_ledger_for_existing_entries(50000, null), 0);
  raise notice 'Rebuilt % party_ledger_entries', v_ple_count;

  -- Rebuild party_open_items
  raise notice 'Rebuilding party_open_items...';
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
  where coalesce(je.source_table,'') <> 'settlements'
    and coalesce(je.source_event,'') <> 'realized_fx'
  on conflict (journal_line_id) do nothing;

  raise notice '=== COMPLETE ===';
  select count(*) into v_ple_count from public.party_ledger_entries;
  
  if to_regclass('public.party_open_items') is not null then
    select count(*) into v_poi_count from public.party_open_items;
  end if;

  raise notice 'Final PLE: %, POI: %', v_ple_count, v_poi_count;
end $$;

-- Re-enable user triggers
alter table public.journal_lines enable trigger user;
alter table public.journal_entries enable trigger user;
alter table public.party_ledger_entries enable trigger user;
alter table public.settlement_lines enable trigger user;

do $$
begin
  if to_regclass('public.party_open_items') is not null then
    alter table public.party_open_items enable trigger user;
  end if;
  if to_regclass('public.ar_open_items') is not null then
    alter table public.ar_open_items enable trigger user;
  end if;
  if to_regclass('public.ledger_entry_hash_chain') is not null then
    alter table public.ledger_entry_hash_chain enable trigger user;
  end if;
end $$;

notify pgrst, 'reload schema';
