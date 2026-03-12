set app.allow_ledger_ddl = '1';

create table if not exists public.fixed_asset_components (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.fixed_assets(id) on delete cascade,
  component_code text unique not null,
  name_ar text not null,
  name_en text,
  acquisition_date date not null,
  cost numeric not null check (cost > 0),
  salvage_value numeric not null default 0 check (salvage_value >= 0),
  useful_life_months int not null check (useful_life_months > 0),
  depreciation_method text not null default 'straight_line',
  accumulated_depreciation numeric not null default 0,
  impairment_accumulated numeric not null default 0,
  status text not null default 'active' check (status in ('active','fully_depreciated','disposed','replaced')),
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_fixed_asset_components_asset on public.fixed_asset_components(asset_id, status);

alter table public.fixed_asset_components enable row level security;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename = 'fixed_asset_components'
      and policyname = 'facp_auth_all'
  ) then
    create policy facp_auth_all
      on public.fixed_asset_components
      for all
      to authenticated
      using (true)
      with check (true);
  end if;
end $$;

create table if not exists public.asset_component_depreciation_entries (
  id uuid primary key default gen_random_uuid(),
  component_id uuid not null references public.fixed_asset_components(id) on delete cascade,
  asset_id uuid not null references public.fixed_assets(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  depreciation_amount numeric not null,
  accumulated_total numeric not null,
  book_value numeric not null,
  journal_entry_id uuid references public.journal_entries(id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (component_id, period_start)
);

create index if not exists idx_acde_component_period on public.asset_component_depreciation_entries(component_id, period_start desc);

alter table public.asset_component_depreciation_entries enable row level security;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename = 'asset_component_depreciation_entries'
      and policyname = 'acde_auth_all'
  ) then
    create policy acde_auth_all
      on public.asset_component_depreciation_entries
      for all
      to authenticated
      using (true)
      with check (true);
  end if;
end $$;

create sequence if not exists public.fixed_asset_component_code_seq start 1;

create or replace function public._next_asset_component_code()
returns text
language sql
security definer
set search_path = public
as $$
  select 'FAC-' || lpad(nextval('public.fixed_asset_component_code_seq')::text, 7, '0');
$$;

create or replace function public.add_asset_component(
  p_asset_id uuid,
  p_name_ar text,
  p_cost numeric,
  p_useful_life_months int,
  p_acquisition_date date default null,
  p_salvage_value numeric default 0,
  p_depreciation_method text default 'straight_line',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset record;
  v_component_id uuid;
  v_asset_total numeric;
  v_existing_components_total numeric;
begin
  perform public._require_staff('add_asset_component');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  if p_asset_id is null then
    raise exception 'asset id is required';
  end if;
  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'component name is required';
  end if;
  if p_cost is null or p_cost <= 0 then
    raise exception 'component cost must be positive';
  end if;
  if p_useful_life_months is null or p_useful_life_months <= 0 then
    raise exception 'component useful life must be positive';
  end if;
  if coalesce(p_salvage_value, 0) < 0 then
    raise exception 'component salvage cannot be negative';
  end if;

  select * into v_asset
  from public.fixed_assets
  where id = p_asset_id
  for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.status = 'disposed' then
    raise exception 'cannot add component to disposed asset';
  end if;
  if public.is_in_closed_period((coalesce(p_acquisition_date, current_date))::timestamptz) then
    raise exception 'Cannot add component in a closed accounting period.';
  end if;

  v_asset_total := coalesce(v_asset.acquisition_cost, 0) + coalesce(v_asset.capitalized_costs, 0);
  select coalesce(sum(c.cost), 0)
  into v_existing_components_total
  from public.fixed_asset_components c
  where c.asset_id = p_asset_id
    and c.status in ('active', 'fully_depreciated');

  if (v_existing_components_total + p_cost) > (v_asset_total + 0.01) then
    raise exception 'components total cost exceeds parent asset total cost';
  end if;

  v_component_id := gen_random_uuid();
  insert into public.fixed_asset_components(
    id, asset_id, component_code, name_ar, acquisition_date, cost, salvage_value,
    useful_life_months, depreciation_method, notes, created_by
  )
  values (
    v_component_id,
    p_asset_id,
    public._next_asset_component_code(),
    btrim(p_name_ar),
    coalesce(p_acquisition_date, v_asset.acquisition_date, current_date),
    p_cost,
    coalesce(p_salvage_value, 0),
    p_useful_life_months,
    case when lower(coalesce(p_depreciation_method, 'straight_line')) in ('straight_line', 'declining_balance') then lower(p_depreciation_method) else 'straight_line' end,
    nullif(trim(coalesce(p_notes, '')), ''),
    auth.uid()
  );

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'fixed_assets.component_add',
    'fixed_assets',
    p_asset_id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'assetId', p_asset_id,
      'componentId', v_component_id,
      'name', p_name_ar,
      'cost', p_cost
    ),
    'MEDIUM',
    'ASSET_COMPONENT_ADD'
  );

  return v_component_id;
end;
$$;

create or replace function public.run_monthly_component_depreciation(
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
  v_comp record;
  v_depreciable numeric;
  v_remaining numeric;
  v_remaining_months int;
  v_prev_acc numeric;
  v_monthly numeric;
  v_depr_amount numeric;
  v_new_acc numeric;
  v_book numeric;
  v_entry_id uuid;
  v_accum_account uuid;
  v_depr_expense uuid;
  v_count int := 0;
begin
  perform public._require_staff('run_monthly_component_depreciation');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;
  if p_year is null or p_month is null or p_month < 1 or p_month > 12 then
    raise exception 'invalid year/month';
  end if;

  v_period_start := make_date(p_year, p_month, 1);
  v_period_end := (v_period_start + interval '1 month' - interval '1 day')::date;
  if public.is_in_closed_period(v_period_end::timestamptz) then
    raise exception 'Cannot run component depreciation in a closed accounting period.';
  end if;

  v_accum_account := public.get_account_id_by_code('1550');
  v_depr_expense := public.get_account_id_by_code('6500');
  if v_accum_account is null or v_depr_expense is null then
    raise exception 'depreciation accounts not found (1550 / 6500)';
  end if;

  for v_comp in
    select c.*, fa.name_ar as asset_name_ar, fa.asset_code
    from public.fixed_asset_components c
    join public.fixed_assets fa on fa.id = c.asset_id
    where c.status = 'active'
      and c.acquisition_date <= v_period_end
      and fa.status <> 'disposed'
    order by c.component_code
  loop
    if exists (
      select 1
      from public.asset_component_depreciation_entries e
      where e.component_id = v_comp.id
        and e.period_start = v_period_start
    ) then
      continue;
    end if;

    select coalesce(max(e.accumulated_total), 0)
    into v_prev_acc
    from public.asset_component_depreciation_entries e
    where e.component_id = v_comp.id;

    v_depreciable := greatest(v_comp.cost - coalesce(v_comp.salvage_value, 0), 0);
    v_remaining := greatest(v_depreciable - v_prev_acc - coalesce(v_comp.impairment_accumulated, 0), 0);
    if v_remaining <= 0.01 then
      update public.fixed_asset_components
      set status = 'fully_depreciated', updated_at = now()
      where id = v_comp.id;
      continue;
    end if;

    v_remaining_months := greatest(
      v_comp.useful_life_months - (
        select count(*)
        from public.asset_component_depreciation_entries e
        where e.component_id = v_comp.id
      ),
      1
    );

    if v_comp.depreciation_method = 'declining_balance' then
      v_monthly := (2.0 / greatest(v_comp.useful_life_months, 1)) * greatest(v_comp.cost - v_prev_acc - coalesce(v_comp.impairment_accumulated, 0), 0);
    else
      v_monthly := v_remaining / v_remaining_months;
    end if;

    v_depr_amount := least(public._money_round(v_monthly), v_remaining);
    if v_depr_amount <= 0 then
      continue;
    end if;

    v_new_acc := v_prev_acc + v_depr_amount;
    v_book := greatest(v_comp.cost - v_new_acc - coalesce(v_comp.impairment_accumulated, 0), 0);

    insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
    values (
      v_period_end,
      concat('إهلاك مكوّن أصل: ', v_comp.name_ar, ' (', v_comp.component_code, ')'),
      'fixed_asset_components',
      v_comp.id::text || ':depreciation_' || to_char(v_period_start, 'YYYY-MM'),
      concat('depreciation_', to_char(v_period_start, 'YYYY-MM')),
      auth.uid(),
      'posted'
    )
    returning id into v_entry_id;

    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values
      (v_entry_id, v_depr_expense, v_depr_amount, 0, concat('إهلاك مكوّن ', v_comp.component_code)),
      (v_entry_id, v_accum_account, 0, v_depr_amount, concat('مجمع إهلاك مكوّن ', v_comp.component_code));

    perform public.check_journal_entry_balance(v_entry_id);

    insert into public.asset_component_depreciation_entries(
      component_id, asset_id, period_start, period_end, depreciation_amount, accumulated_total, book_value, journal_entry_id, created_by
    )
    values (
      v_comp.id, v_comp.asset_id, v_period_start, v_period_end, v_depr_amount, v_new_acc, v_book, v_entry_id, auth.uid()
    )
    on conflict (component_id, period_start) do update
    set depreciation_amount = excluded.depreciation_amount,
        accumulated_total = excluded.accumulated_total,
        book_value = excluded.book_value,
        journal_entry_id = excluded.journal_entry_id;

    update public.fixed_asset_components
    set accumulated_depreciation = v_new_acc,
        status = case when v_book <= coalesce(v_comp.salvage_value, 0) + 0.01 then 'fully_depreciated' else status end,
        updated_at = now()
    where id = v_comp.id;

    v_count := v_count + 1;
  end loop;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'fixed_assets.component_depreciation_run',
    'fixed_assets',
    concat(p_year, '-', lpad(p_month::text, 2, '0')),
    auth.uid(),
    now(),
    jsonb_build_object('year', p_year, 'month', p_month, 'componentsProcessed', v_count),
    'MEDIUM',
    'COMPONENT_DEPRECIATION_RUN'
  );

  return v_count;
end;
$$;

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
  v_component_total_cost numeric;
  v_component_accum_depr numeric;
  v_component_impairment numeric;
  v_remaining_months int;
  v_component_runs int := 0;
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
  if public.is_in_closed_period(v_period_end::timestamptz) then
    raise exception 'Cannot run depreciation in a closed accounting period.';
  end if;

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

    select coalesce(max(ade.accumulated_total), 0)
    into v_prev_accumulated
    from public.asset_depreciation_entries ade
    where ade.asset_id = v_asset.id;

    select coalesce(sum(c.cost), 0), coalesce(sum(c.accumulated_depreciation), 0), coalesce(sum(c.impairment_accumulated), 0)
    into v_component_total_cost, v_component_accum_depr, v_component_impairment
    from public.fixed_asset_components c
    where c.asset_id = v_asset.id
      and c.status in ('active', 'fully_depreciated');

    v_remaining := greatest(
      (v_depreciable - v_prev_accumulated - coalesce(v_asset.impairment_accumulated, 0))
      - greatest(v_component_total_cost - v_component_accum_depr - v_component_impairment, 0),
      0
    );

    if v_remaining <= 0.01 then
      update public.fixed_assets set status = 'fully_depreciated', updated_at = now() where id = v_asset.id;
      continue;
    end if;

    v_remaining_months := greatest(
      coalesce(v_asset.useful_life_months, 1) - (
        select count(*)
        from public.asset_depreciation_entries ade2
        where ade2.asset_id = v_asset.id
      ),
      1
    );

    if v_asset.depreciation_method = 'declining_balance' then
      v_monthly_depr := (2.0 / greatest(coalesce(v_asset.useful_life_months, 60), 1))
        * greatest(v_total_cost - v_prev_accumulated - coalesce(v_asset.impairment_accumulated, 0), 0);
      v_monthly_depr := greatest(v_monthly_depr, 0);
    else
      v_monthly_depr := v_remaining / v_remaining_months;
    end if;

    v_depr_amount := least(public._money_round(v_monthly_depr), v_remaining);
    if v_depr_amount <= 0 then continue; end if;

    v_new_accumulated := v_prev_accumulated + v_depr_amount;
    v_new_book_value := greatest(v_total_cost - v_new_accumulated - coalesce(v_asset.impairment_accumulated, 0), 0);

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

    insert into public.asset_depreciation_entries(asset_id, period_start, period_end, depreciation_amount, accumulated_total, book_value, journal_entry_id, created_by)
    values (v_asset.id, v_period_start, v_period_end, v_depr_amount, v_new_accumulated, v_new_book_value, v_entry_id, auth.uid())
    on conflict (asset_id, period_start) do update
    set depreciation_amount = excluded.depreciation_amount,
        accumulated_total = excluded.accumulated_total,
        book_value = excluded.book_value,
        journal_entry_id = excluded.journal_entry_id;

    if v_new_book_value <= coalesce(v_asset.salvage_value, 0) + 0.01 then
      update public.fixed_assets set status = 'fully_depreciated', updated_at = now() where id = v_asset.id;
    end if;

    v_count := v_count + 1;
  end loop;

  begin
    select public.run_monthly_component_depreciation(p_year, p_month) into v_component_runs;
  exception when others then
    v_component_runs := 0;
  end;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('fixed_assets.depreciation_run', 'fixed_assets', concat(p_year, '-', lpad(p_month::text, 2, '0')), auth.uid(), now(),
    jsonb_build_object('year', p_year, 'month', p_month, 'assetsProcessed', v_count, 'componentProcessed', v_component_runs),
    'MEDIUM', 'DEPRECIATION_RUN');

  return v_count + v_component_runs;
end;
$$;

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
    ), 0) + coalesce((
      select sum(c.accumulated_depreciation)
      from public.fixed_asset_components c
      join public.fixed_assets fa on fa.id = c.asset_id
      where fa.status <> 'disposed'
    ), 0),
    'netBookValue', coalesce((
      select sum(
        (fa.acquisition_cost + fa.capitalized_costs)
        - coalesce((
            select max(ade.accumulated_total)
            from public.asset_depreciation_entries ade
            where ade.asset_id = fa.id
          ), 0)
        - coalesce(fa.impairment_accumulated, 0)
      )
      from public.fixed_assets fa
      where fa.status <> 'disposed'
    ), 0) - coalesce((
      select sum(c.accumulated_depreciation + c.impairment_accumulated)
      from public.fixed_asset_components c
      join public.fixed_assets fa on fa.id = c.asset_id
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

revoke all on function public.add_asset_component(uuid, text, numeric, int, date, numeric, text, text) from public;
grant execute on function public.add_asset_component(uuid, text, numeric, int, date, numeric, text, text) to authenticated;
revoke all on function public.run_monthly_component_depreciation(int, int) from public;
grant execute on function public.run_monthly_component_depreciation(int, int) to authenticated;
revoke all on function public.run_monthly_depreciation(int, int) from public;
grant execute on function public.run_monthly_depreciation(int, int) to authenticated;
revoke all on function public.get_fixed_assets_summary() from public;
grant execute on function public.get_fixed_assets_summary() to authenticated;

notify pgrst, 'reload schema';
