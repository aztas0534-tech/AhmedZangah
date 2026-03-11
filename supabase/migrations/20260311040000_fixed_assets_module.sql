-- ============================================================================
-- FIXED ASSETS MODULE (IAS 16) — الأصول الثابتة
-- Tables, COA accounts, RPCs for asset management & depreciation
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════
-- STEP 1: COA Accounts for Fixed Assets
-- ═══════════════════════════════════════════════════════════════

insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
values
  ('1500', 'الأصول الثابتة | Fixed Assets', 'asset', 'debit', true),
  ('1510', 'مركبات ووسائل نقل | Vehicles & Transport', 'asset', 'debit', true),
  ('1520', 'أثاث ومعدات مكتبية | Furniture & Equipment', 'asset', 'debit', true),
  ('1530', 'ديكورات وتحسينات | Leasehold Improvements', 'asset', 'debit', true),
  ('1540', 'أجهزة إلكترونية | Electronic Equipment', 'asset', 'debit', true),
  ('1550', 'مجمع الإهلاك | Accumulated Depreciation', 'asset', 'credit', true),
  ('6500', 'مصروف الإهلاك | Depreciation Expense', 'expense', 'debit', true),
  ('4030', 'أرباح/خسائر استبعاد أصول | Gain/Loss on Disposal', 'income', 'credit', true)
on conflict (code) do update
set name = excluded.name,
    account_type = excluded.account_type,
    normal_balance = excluded.normal_balance,
    is_active = true;


-- ═══════════════════════════════════════════════════════════════
-- STEP 2: Asset Categories Table
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.fixed_asset_categories (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name_ar text not null,
  name_en text,
  account_code text not null default '1500',
  depreciation_method text not null default 'straight_line',
  default_useful_life_months int not null default 60,
  default_salvage_pct numeric not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.fixed_asset_categories enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'fixed_asset_categories' and policyname = 'fac_auth_all') then
    create policy fac_auth_all on public.fixed_asset_categories for all to authenticated using (true) with check (true);
  end if;
end $$;

-- Seed default categories
insert into public.fixed_asset_categories(code, name_ar, name_en, account_code, depreciation_method, default_useful_life_months, default_salvage_pct)
values
  ('vehicles',    'مركبات ووسائل نقل',  'Vehicles & Transport',     '1510', 'straight_line', 60,  5),
  ('furniture',   'أثاث ومعدات مكتبية', 'Furniture & Equipment',    '1520', 'straight_line', 120, 0),
  ('leasehold',   'ديكورات وتحسينات',   'Leasehold Improvements',   '1530', 'straight_line', 60,  0),
  ('electronics', 'أجهزة إلكترونية',    'Electronic Equipment',     '1540', 'straight_line', 36,  0),
  ('other',       'أصول أخرى',          'Other Assets',             '1500', 'straight_line', 60,  0)
on conflict (code) do nothing;


-- ═══════════════════════════════════════════════════════════════
-- STEP 3: Fixed Assets Table
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.fixed_assets (
  id uuid primary key default gen_random_uuid(),
  asset_code text unique not null,
  name_ar text not null,
  name_en text,
  category_id uuid references public.fixed_asset_categories(id),
  acquisition_date date not null,
  acquisition_cost numeric not null default 0 check (acquisition_cost >= 0),
  capitalized_costs numeric not null default 0 check (capitalized_costs >= 0),
  salvage_value numeric not null default 0 check (salvage_value >= 0),
  useful_life_months int not null default 60 check (useful_life_months > 0),
  depreciation_method text not null default 'straight_line',
  status text not null default 'active' check (status in ('active','disposed','fully_depreciated')),
  location text,
  serial_number text,
  warehouse_id uuid,
  disposed_at timestamptz,
  disposal_amount numeric not null default 0,
  disposal_method text,
  notes text,
  data jsonb not null default '{}',
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_fa_status on public.fixed_assets(status);
create index if not exists idx_fa_category on public.fixed_assets(category_id);
create index if not exists idx_fa_acq_date on public.fixed_assets(acquisition_date);

alter table public.fixed_assets enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'fixed_assets' and policyname = 'fa_auth_all') then
    create policy fa_auth_all on public.fixed_assets for all to authenticated using (true) with check (true);
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- STEP 4: Depreciation Entries Table
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.asset_depreciation_entries (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.fixed_assets(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  depreciation_amount numeric not null check (depreciation_amount >= 0),
  accumulated_total numeric not null,
  book_value numeric not null,
  journal_entry_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique(asset_id, period_start)
);

create index if not exists idx_ade_asset on public.asset_depreciation_entries(asset_id);
create index if not exists idx_ade_period on public.asset_depreciation_entries(period_start);

alter table public.asset_depreciation_entries enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'asset_depreciation_entries' and policyname = 'ade_auth_all') then
    create policy ade_auth_all on public.asset_depreciation_entries for all to authenticated using (true) with check (true);
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- STEP 5: Auto-increment asset code sequence
-- ═══════════════════════════════════════════════════════════════

create sequence if not exists public.fixed_asset_code_seq start 1;

create or replace function public._next_asset_code()
returns text
language sql
security definer
set search_path = public
as $$
  select 'FA-' || lpad(nextval('public.fixed_asset_code_seq')::text, 6, '0');
$$;


-- ═══════════════════════════════════════════════════════════════
-- STEP 6: RPC — register_fixed_asset
-- ═══════════════════════════════════════════════════════════════

create or replace function public.register_fixed_asset(
  p_name_ar text,
  p_category_code text,
  p_acquisition_date date,
  p_acquisition_cost numeric,
  p_payment_method text default 'cash',
  p_useful_life_months int default null,
  p_salvage_value numeric default 0,
  p_location text default null,
  p_serial_number text default null,
  p_notes text default null,
  p_name_en text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset_id uuid;
  v_cat record;
  v_asset_account uuid;
  v_credit_account uuid;
  v_entry_id uuid;
  v_total_cost numeric;
  v_useful int;
begin
  perform public._require_staff('register_fixed_asset');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'asset name is required';
  end if;
  if p_acquisition_cost is null or p_acquisition_cost <= 0 then
    raise exception 'acquisition cost must be positive';
  end if;
  if p_acquisition_date is null then
    raise exception 'acquisition date is required';
  end if;

  select * into v_cat
  from public.fixed_asset_categories c
  where c.code = coalesce(p_category_code, 'other')
    and c.is_active = true;
  if not found then
    raise exception 'invalid asset category: %', p_category_code;
  end if;

  v_useful := coalesce(p_useful_life_months, v_cat.default_useful_life_months, 60);
  v_total_cost := p_acquisition_cost;

  v_asset_id := gen_random_uuid();
  insert into public.fixed_assets(
    id, asset_code, name_ar, name_en, category_id,
    acquisition_date, acquisition_cost, salvage_value,
    useful_life_months, depreciation_method,
    location, serial_number, notes, created_by
  )
  values (
    v_asset_id,
    public._next_asset_code(),
    btrim(p_name_ar),
    nullif(btrim(coalesce(p_name_en,'')), ''),
    v_cat.id,
    p_acquisition_date,
    p_acquisition_cost,
    coalesce(p_salvage_value, (p_acquisition_cost * v_cat.default_salvage_pct / 100)),
    v_useful,
    v_cat.depreciation_method,
    nullif(btrim(coalesce(p_location,'')), ''),
    nullif(btrim(coalesce(p_serial_number,'')), ''),
    nullif(btrim(coalesce(p_notes,'')), ''),
    auth.uid()
  );

  -- GL: Dr Asset Account / Cr Cash or AP
  v_asset_account := public.get_account_id_by_code(v_cat.account_code);
  if v_asset_account is null then
    v_asset_account := public.get_account_id_by_code('1500');
  end if;

  if p_payment_method = 'credit' or p_payment_method = 'ap' then
    v_credit_account := public.get_account_id_by_code('2010'); -- AP
  else
    v_credit_account := public.get_account_id_by_code('1010'); -- Cash
  end if;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (p_acquisition_date, concat('تسجيل أصل ثابت: ', btrim(p_name_ar)), 'fixed_assets', v_asset_id::text || ':acquisition', 'acquisition', auth.uid(), 'posted')
  returning id into v_entry_id;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values
    (v_entry_id, v_asset_account, public._money_round(v_total_cost), 0, 'شراء أصل ثابت'),
    (v_entry_id, v_credit_account, 0, public._money_round(v_total_cost), case when p_payment_method = 'credit' then 'ذمم دائنة' else 'نقداً' end);

  perform public.check_journal_entry_balance(v_entry_id);

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('fixed_assets.register', 'fixed_assets', v_asset_id::text, auth.uid(), now(),
    jsonb_build_object('assetId', v_asset_id, 'name', p_name_ar, 'cost', p_acquisition_cost, 'category', p_category_code),
    'MEDIUM', 'ASSET_REGISTER');

  return v_asset_id;
end;
$$;

revoke all on function public.register_fixed_asset(text, text, date, numeric, text, int, numeric, text, text, text, text) from public;
grant execute on function public.register_fixed_asset(text, text, date, numeric, text, int, numeric, text, text, text, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- STEP 7: RPC — capitalize_asset_cost
-- ═══════════════════════════════════════════════════════════════

create or replace function public.capitalize_asset_cost(
  p_asset_id uuid,
  p_amount numeric,
  p_description text default null,
  p_payment_method text default 'cash'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset record;
  v_cat record;
  v_asset_account uuid;
  v_credit_account uuid;
  v_entry_id uuid;
  v_cap_uid text;
begin
  perform public._require_staff('capitalize_asset_cost');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;

  select * into v_asset from public.fixed_assets where id = p_asset_id for update;
  if not found then raise exception 'asset not found'; end if;
  if v_asset.status <> 'active' then
    raise exception 'cannot capitalize cost on non-active asset';
  end if;

  select * into v_cat from public.fixed_asset_categories where id = v_asset.category_id;

  update public.fixed_assets
  set capitalized_costs = capitalized_costs + p_amount,
      updated_at = now()
  where id = p_asset_id;

  -- GL: Dr Asset Account / Cr Cash or AP
  v_asset_account := public.get_account_id_by_code(coalesce(v_cat.account_code, '1500'));
  if v_asset_account is null then v_asset_account := public.get_account_id_by_code('1500'); end if;

  if p_payment_method = 'credit' or p_payment_method = 'ap' then
    v_credit_account := public.get_account_id_by_code('2010');
  else
    v_credit_account := public.get_account_id_by_code('1010');
  end if;

  v_cap_uid := gen_random_uuid()::text;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (current_date, concat('رسملة تكلفة على أصل: ', v_asset.name_ar, ' - ', coalesce(p_description, '')),
    'fixed_assets', p_asset_id::text || ':capitalize_' || v_cap_uid, concat('capitalize_', v_cap_uid), auth.uid(), 'posted')
  returning id into v_entry_id;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values
    (v_entry_id, v_asset_account, public._money_round(p_amount), 0, coalesce(p_description, 'رسملة تكلفة إضافية')),
    (v_entry_id, v_credit_account, 0, public._money_round(p_amount), case when p_payment_method = 'credit' then 'ذمم دائنة' else 'نقداً' end);

  perform public.check_journal_entry_balance(v_entry_id);

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('fixed_assets.capitalize', 'fixed_assets', p_asset_id::text, auth.uid(), now(),
    jsonb_build_object('assetId', p_asset_id, 'amount', p_amount, 'description', p_description),
    'MEDIUM', 'ASSET_CAPITALIZE');
end;
$$;

revoke all on function public.capitalize_asset_cost(uuid, numeric, text, text) from public;
grant execute on function public.capitalize_asset_cost(uuid, numeric, text, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- STEP 8: RPC — run_monthly_depreciation
-- ═══════════════════════════════════════════════════════════════

create or replace function public.run_monthly_depreciation(
  p_year int,
  p_month int
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period_start date;
  v_period_end date;
  v_asset record;
  v_total_cost numeric;
  v_depreciable numeric;
  v_monthly_depr numeric;
  v_prev_accumulated numeric;
  v_remaining numeric;
  v_depr_amount numeric;
  v_new_accumulated numeric;
  v_new_book_value numeric;
  v_entry_id uuid;
  v_accum_account uuid;
  v_depr_expense uuid;
  v_count int := 0;
begin
  perform public._require_staff('run_monthly_depreciation');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  if p_year is null or p_month is null or p_month < 1 or p_month > 12 then
    raise exception 'invalid year/month';
  end if;

  v_period_start := make_date(p_year, p_month, 1);
  v_period_end := (v_period_start + interval '1 month' - interval '1 day')::date;

  v_accum_account := public.get_account_id_by_code('1550');
  v_depr_expense := public.get_account_id_by_code('6500');
  if v_accum_account is null or v_depr_expense is null then
    raise exception 'depreciation accounts not found (1550 / 6500)';
  end if;

  for v_asset in
    select fa.*, fac.account_code
    from public.fixed_assets fa
    left join public.fixed_asset_categories fac on fac.id = fa.category_id
    where fa.status = 'active'
      and fa.acquisition_date <= v_period_end
    order by fa.asset_code
  loop
    -- Skip if already depreciated for this period
    if exists (
      select 1 from public.asset_depreciation_entries
      where asset_id = v_asset.id and period_start = v_period_start
    ) then
      continue;
    end if;

    v_total_cost := coalesce(v_asset.acquisition_cost, 0) + coalesce(v_asset.capitalized_costs, 0);
    v_depreciable := greatest(v_total_cost - coalesce(v_asset.salvage_value, 0), 0);

    if v_depreciable <= 0 or coalesce(v_asset.useful_life_months, 0) <= 0 then
      continue;
    end if;

    -- Get previous accumulated depreciation
    select coalesce(max(ade.accumulated_total), 0)
    into v_prev_accumulated
    from public.asset_depreciation_entries ade
    where ade.asset_id = v_asset.id;

    v_remaining := greatest(v_depreciable - v_prev_accumulated, 0);
    if v_remaining <= 0.01 then
      -- Fully depreciated
      update public.fixed_assets set status = 'fully_depreciated', updated_at = now() where id = v_asset.id;
      continue;
    end if;

    -- Straight-line monthly depreciation
    if v_asset.depreciation_method = 'declining_balance' then
      -- Declining: 2/n * remaining book value
      v_monthly_depr := (2.0 / coalesce(v_asset.useful_life_months, 60)) * (v_total_cost - v_prev_accumulated);
      v_monthly_depr := greatest(v_monthly_depr, 0);
    else
      -- Straight-line: depreciable / useful_life
      v_monthly_depr := v_depreciable / v_asset.useful_life_months;
    end if;

    v_depr_amount := least(public._money_round(v_monthly_depr), v_remaining);
    if v_depr_amount <= 0 then continue; end if;

    v_new_accumulated := v_prev_accumulated + v_depr_amount;
    v_new_book_value := v_total_cost - v_new_accumulated;

    -- GL: Dr Depreciation Expense 6500 / Cr Accumulated Depreciation 1550
    insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
    values (
      v_period_end,
      concat('إهلاك شهري: ', v_asset.name_ar, ' (', v_asset.asset_code, ')'),
      'fixed_assets',
      v_asset.id::text || ':depreciation_' || to_char(v_period_start, 'YYYY-MM'),
      concat('depreciation_', to_char(v_period_start, 'YYYY-MM')),
      auth.uid(),
      'posted'
    )
    returning id into v_entry_id;

    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_depr_expense, v_depr_amount, 0, concat('إهلاك ', v_asset.asset_code)),
      (v_entry_id, v_accum_account, 0, v_depr_amount, concat('مجمع إهلاك ', v_asset.asset_code));

    -- Record depreciation entry
    insert into public.asset_depreciation_entries(asset_id, period_start, period_end, depreciation_amount, accumulated_total, book_value, journal_entry_id, created_by)
    values (v_asset.id, v_period_start, v_period_end, v_depr_amount, v_new_accumulated, v_new_book_value, v_entry_id, auth.uid())
    on conflict (asset_id, period_start) do update
    set depreciation_amount = excluded.depreciation_amount,
        accumulated_total = excluded.accumulated_total,
        book_value = excluded.book_value,
        journal_entry_id = excluded.journal_entry_id;

    -- Auto-mark fully depreciated
    if v_new_book_value <= coalesce(v_asset.salvage_value, 0) + 0.01 then
      update public.fixed_assets set status = 'fully_depreciated', updated_at = now() where id = v_asset.id;
    end if;

    v_count := v_count + 1;
  end loop;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('fixed_assets.depreciation_run', 'fixed_assets', concat(p_year, '-', lpad(p_month::text, 2, '0')), auth.uid(), now(),
    jsonb_build_object('year', p_year, 'month', p_month, 'assetsProcessed', v_count),
    'MEDIUM', 'DEPRECIATION_RUN');

  return v_count;
end;
$$;

revoke all on function public.run_monthly_depreciation(int, int) from public;
grant execute on function public.run_monthly_depreciation(int, int) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- STEP 9: RPC — dispose_fixed_asset
-- ═══════════════════════════════════════════════════════════════

create or replace function public.dispose_fixed_asset(
  p_asset_id uuid,
  p_disposal_amount numeric default 0,
  p_disposal_method text default 'scrap',
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset record;
  v_cat record;
  v_total_cost numeric;
  v_accumulated numeric;
  v_book_value numeric;
  v_gain_loss numeric;
  v_entry_id uuid;
  v_asset_account uuid;
  v_accum_account uuid;
  v_gl_account uuid;
  v_cash_account uuid;
begin
  perform public._require_staff('dispose_fixed_asset');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  select * into v_asset from public.fixed_assets where id = p_asset_id for update;
  if not found then raise exception 'asset not found'; end if;
  if v_asset.status = 'disposed' then
    raise exception 'asset already disposed';
  end if;

  select * into v_cat from public.fixed_asset_categories where id = v_asset.category_id;

  v_total_cost := coalesce(v_asset.acquisition_cost, 0) + coalesce(v_asset.capitalized_costs, 0);

  select coalesce(max(ade.accumulated_total), 0)
  into v_accumulated
  from public.asset_depreciation_entries ade
  where ade.asset_id = p_asset_id;

  v_book_value := v_total_cost - v_accumulated;
  v_gain_loss := coalesce(p_disposal_amount, 0) - v_book_value;

  -- Update asset status
  update public.fixed_assets
  set status = 'disposed',
      disposed_at = now(),
      disposal_amount = coalesce(p_disposal_amount, 0),
      disposal_method = coalesce(p_disposal_method, 'scrap'),
      updated_at = now()
  where id = p_asset_id;

  -- GL Entry for disposal
  v_asset_account := public.get_account_id_by_code(coalesce(v_cat.account_code, '1500'));
  if v_asset_account is null then v_asset_account := public.get_account_id_by_code('1500'); end if;
  v_accum_account := public.get_account_id_by_code('1550');
  v_gl_account := public.get_account_id_by_code('4030');
  v_cash_account := public.get_account_id_by_code('1010');

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (current_date, concat('استبعاد أصل: ', v_asset.name_ar, ' (', v_asset.asset_code, ')'),
    'fixed_assets', p_asset_id::text || ':disposal', 'disposal', auth.uid(), 'posted')
  returning id into v_entry_id;

  -- Dr Accumulated Depreciation (remove)
  if v_accumulated > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_accum_account, public._money_round(v_accumulated), 0, 'إزالة مجمع الإهلاك');
  end if;

  -- Dr Cash (if sold)
  if coalesce(p_disposal_amount, 0) > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_cash_account, public._money_round(p_disposal_amount), 0, 'حصيلة بيع الأصل');
  end if;

  -- Cr Asset Account (remove full cost)
  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values (v_entry_id, v_asset_account, 0, public._money_round(v_total_cost), 'إزالة الأصل الثابت');

  -- Dr/Cr Gain/Loss
  if v_gain_loss > 0 then
    -- Gain on disposal: Cr 4030
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_gl_account, 0, public._money_round(v_gain_loss), 'ربح استبعاد أصل');
  elsif v_gain_loss < 0 then
    -- Loss on disposal: Dr 4030
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (v_entry_id, v_gl_account, public._money_round(abs(v_gain_loss)), 0, 'خسارة استبعاد أصل');
  end if;

  perform public.check_journal_entry_balance(v_entry_id);

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('fixed_assets.dispose', 'fixed_assets', p_asset_id::text, auth.uid(), now(),
    jsonb_build_object('assetId', p_asset_id, 'disposalAmount', p_disposal_amount, 'bookValue', v_book_value, 'gainLoss', v_gain_loss, 'method', p_disposal_method),
    'HIGH', 'ASSET_DISPOSE');
end;
$$;

revoke all on function public.dispose_fixed_asset(uuid, numeric, text, text) from public;
grant execute on function public.dispose_fixed_asset(uuid, numeric, text, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- STEP 10: RPC — get_fixed_assets_summary
-- ═══════════════════════════════════════════════════════════════

create or replace function public.get_fixed_assets_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'totalAssets', (select count(*) from public.fixed_assets where status <> 'disposed'),
    'disposedAssets', (select count(*) from public.fixed_assets where status = 'disposed'),
    'totalCost', coalesce((select sum(acquisition_cost + capitalized_costs) from public.fixed_assets where status <> 'disposed'), 0),
    'totalAccumulatedDepreciation', coalesce((
      select sum(ade.accumulated_total)
      from (
        select distinct on (ade2.asset_id) ade2.accumulated_total
        from public.asset_depreciation_entries ade2
        join public.fixed_assets fa on fa.id = ade2.asset_id and fa.status <> 'disposed'
        order by ade2.asset_id, ade2.period_start desc
      ) ade
    ), 0),
    'netBookValue', coalesce((
      select sum(
        (fa.acquisition_cost + fa.capitalized_costs) -
        coalesce((
          select max(ade.accumulated_total)
          from public.asset_depreciation_entries ade
          where ade.asset_id = fa.id
        ), 0)
      )
      from public.fixed_assets fa
      where fa.status <> 'disposed'
    ), 0),
    'categorySummary', coalesce((
      select jsonb_agg(jsonb_build_object(
        'category', fac.name_ar,
        'count', cat_data.cnt,
        'totalCost', cat_data.total_cost
      ))
      from (
        select fa.category_id, count(*) as cnt, sum(fa.acquisition_cost + fa.capitalized_costs) as total_cost
        from public.fixed_assets fa
        where fa.status <> 'disposed'
        group by fa.category_id
      ) cat_data
      join public.fixed_asset_categories fac on fac.id = cat_data.category_id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_fixed_assets_summary() from public;
grant execute on function public.get_fixed_assets_summary() to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- PostgREST reload
-- ═══════════════════════════════════════════════════════════════
select pg_sleep(0.3);
notify pgrst, 'reload schema';
notify pgrst, 'reload config';
