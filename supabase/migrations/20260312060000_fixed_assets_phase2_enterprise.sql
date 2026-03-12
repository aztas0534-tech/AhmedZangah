set app.allow_ledger_ddl = '1';

insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
values
  ('1560', 'مخصص انخفاض قيمة الأصول | Asset Impairment Allowance', 'asset', 'credit', true),
  ('6510', 'خسارة انخفاض قيمة الأصول | Asset Impairment Loss', 'expense', 'debit', true)
on conflict (code) do update
set name = excluded.name,
    account_type = excluded.account_type,
    normal_balance = excluded.normal_balance,
    is_active = true;

alter table public.fixed_assets
  add column if not exists impairment_accumulated numeric not null default 0;

create table if not exists public.asset_impairment_entries (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.fixed_assets(id) on delete cascade,
  impairment_date date not null,
  impairment_amount numeric not null check (impairment_amount > 0),
  accumulated_impairment numeric not null default 0,
  carrying_amount_before numeric not null default 0,
  carrying_amount_after numeric not null default 0,
  reason text,
  journal_entry_id uuid references public.journal_entries(id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now()
);

create index if not exists idx_asset_impairment_asset_date
  on public.asset_impairment_entries(asset_id, impairment_date desc);

alter table public.asset_impairment_entries enable row level security;

do $$ begin
  if not exists (
    select 1
    from pg_policies
    where tablename = 'asset_impairment_entries'
      and policyname = 'aie_auth_all'
  ) then
    create policy aie_auth_all
      on public.asset_impairment_entries
      for all
      to authenticated
      using (true)
      with check (true);
  end if;
end $$;

create table if not exists public.asset_transfer_entries (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.fixed_assets(id) on delete cascade,
  transfer_date date not null default current_date,
  from_location text,
  to_location text not null,
  from_warehouse_id uuid,
  to_warehouse_id uuid,
  reason text,
  created_by uuid,
  created_at timestamptz not null default now()
);

create index if not exists idx_asset_transfer_asset_date
  on public.asset_transfer_entries(asset_id, transfer_date desc);

alter table public.asset_transfer_entries enable row level security;

do $$ begin
  if not exists (
    select 1
    from pg_policies
    where tablename = 'asset_transfer_entries'
      and policyname = 'ate_auth_all'
  ) then
    create policy ate_auth_all
      on public.asset_transfer_entries
      for all
      to authenticated
      using (true)
      with check (true);
  end if;
end $$;

create or replace function public.trg_fixed_assets_block_closed_period()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if public.is_in_closed_period((new.acquisition_date)::timestamptz) then
      raise exception 'Cannot register fixed asset in a closed accounting period.';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    if new.acquisition_date is distinct from old.acquisition_date then
      if public.is_in_closed_period((new.acquisition_date)::timestamptz) then
        raise exception 'Cannot change asset acquisition date into a closed accounting period.';
      end if;
    end if;
    if (new.capitalized_costs is distinct from old.capitalized_costs) and public.is_in_closed_period(now()) then
      raise exception 'Cannot capitalize asset cost while current accounting period is closed.';
    end if;
    if (new.status = 'disposed' and old.status is distinct from 'disposed') and public.is_in_closed_period(now()) then
      raise exception 'Cannot dispose fixed asset while current accounting period is closed.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_fixed_assets_block_closed_period on public.fixed_assets;
create trigger trg_fixed_assets_block_closed_period
before insert or update on public.fixed_assets
for each row execute function public.trg_fixed_assets_block_closed_period();

create or replace function public.trg_asset_impairment_block_closed_period()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_in_closed_period((new.impairment_date)::timestamptz) then
    raise exception 'Cannot post impairment in a closed accounting period.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_asset_impairment_block_closed_period on public.asset_impairment_entries;
create trigger trg_asset_impairment_block_closed_period
before insert or update on public.asset_impairment_entries
for each row execute function public.trg_asset_impairment_block_closed_period();

create or replace function public.trg_asset_transfer_block_closed_period()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_in_closed_period((new.transfer_date)::timestamptz) then
    raise exception 'Cannot transfer asset in a closed accounting period.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_asset_transfer_block_closed_period on public.asset_transfer_entries;
create trigger trg_asset_transfer_block_closed_period
before insert or update on public.asset_transfer_entries
for each row execute function public.trg_asset_transfer_block_closed_period();

create or replace function public.post_asset_impairment(
  p_asset_id uuid,
  p_impairment_amount numeric,
  p_reason text default null,
  p_impairment_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset record;
  v_total_cost numeric;
  v_accum_depr numeric;
  v_impairment_accum numeric;
  v_carrying_before numeric;
  v_allowed numeric;
  v_amount numeric;
  v_entry_id uuid;
  v_allowance_account uuid;
  v_loss_account uuid;
  v_new_impairment_accum numeric;
begin
  perform public._require_staff('post_asset_impairment');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  if p_asset_id is null then
    raise exception 'asset id is required';
  end if;
  if p_impairment_amount is null or p_impairment_amount <= 0 then
    raise exception 'impairment amount must be positive';
  end if;
  if p_impairment_date is null then
    raise exception 'impairment date is required';
  end if;
  if public.is_in_closed_period((p_impairment_date)::timestamptz) then
    raise exception 'Cannot post impairment in a closed accounting period.';
  end if;

  select * into v_asset
  from public.fixed_assets
  where id = p_asset_id
  for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.status = 'disposed' then
    raise exception 'cannot impair disposed asset';
  end if;

  v_total_cost := coalesce(v_asset.acquisition_cost, 0) + coalesce(v_asset.capitalized_costs, 0);
  select coalesce(max(ade.accumulated_total), 0)
    into v_accum_depr
  from public.asset_depreciation_entries ade
  where ade.asset_id = p_asset_id;
  v_impairment_accum := coalesce(v_asset.impairment_accumulated, 0);
  v_carrying_before := greatest(v_total_cost - v_accum_depr - v_impairment_accum, 0);
  v_allowed := greatest(v_carrying_before - coalesce(v_asset.salvage_value, 0), 0);
  if v_allowed <= 0 then
    raise exception 'no impairment room left above salvage value';
  end if;

  v_amount := least(public._money_round(p_impairment_amount), public._money_round(v_allowed));
  if v_amount <= 0 then
    raise exception 'impairment amount is too small';
  end if;

  v_allowance_account := public.get_account_id_by_code('1560');
  v_loss_account := public.get_account_id_by_code('6510');
  if v_allowance_account is null or v_loss_account is null then
    raise exception 'impairment accounts not found (1560 / 6510)';
  end if;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (
    p_impairment_date,
    concat('انخفاض قيمة أصل: ', v_asset.name_ar, ' (', v_asset.asset_code, ')'),
    'fixed_assets',
    p_asset_id::text || ':impairment_' || to_char(p_impairment_date, 'YYYY-MM-DD'),
    concat('impairment_', to_char(p_impairment_date, 'YYYYMMDD')),
    auth.uid(),
    'posted'
  )
  returning id into v_entry_id;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values
    (v_entry_id, v_loss_account, v_amount, 0, concat('خسارة انخفاض قيمة ', v_asset.asset_code)),
    (v_entry_id, v_allowance_account, 0, v_amount, concat('مخصص انخفاض قيمة ', v_asset.asset_code));

  perform public.check_journal_entry_balance(v_entry_id);

  v_new_impairment_accum := v_impairment_accum + v_amount;
  update public.fixed_assets
  set impairment_accumulated = v_new_impairment_accum,
      updated_at = now()
  where id = p_asset_id;

  insert into public.asset_impairment_entries(
    asset_id, impairment_date, impairment_amount, accumulated_impairment,
    carrying_amount_before, carrying_amount_after, reason, journal_entry_id, created_by
  )
  values (
    p_asset_id,
    p_impairment_date,
    v_amount,
    v_new_impairment_accum,
    v_carrying_before,
    greatest(v_carrying_before - v_amount, 0),
    nullif(trim(coalesce(p_reason, '')), ''),
    v_entry_id,
    auth.uid()
  );

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'fixed_assets.impairment',
    'fixed_assets',
    p_asset_id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'assetId', p_asset_id,
      'impairmentAmount', v_amount,
      'impairmentDate', p_impairment_date,
      'reason', nullif(trim(coalesce(p_reason, '')), '')
    ),
    'HIGH',
    'ASSET_IMPAIRMENT'
  );

  return jsonb_build_object(
    'success', true,
    'assetId', p_asset_id::text,
    'impairmentAmount', v_amount,
    'carryingBefore', v_carrying_before,
    'carryingAfter', greatest(v_carrying_before - v_amount, 0)
  );
end;
$$;

create or replace function public.transfer_fixed_asset(
  p_asset_id uuid,
  p_new_location text,
  p_new_warehouse_id uuid default null,
  p_reason text default null,
  p_transfer_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset record;
  v_new_location text := nullif(trim(coalesce(p_new_location, '')), '');
begin
  perform public._require_staff('transfer_fixed_asset');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  if p_asset_id is null then
    raise exception 'asset id is required';
  end if;
  if v_new_location is null then
    raise exception 'new location is required';
  end if;
  if p_transfer_date is null then
    raise exception 'transfer date is required';
  end if;
  if public.is_in_closed_period((p_transfer_date)::timestamptz) then
    raise exception 'Cannot transfer asset in a closed accounting period.';
  end if;

  select * into v_asset
  from public.fixed_assets
  where id = p_asset_id
  for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.status = 'disposed' then
    raise exception 'cannot transfer disposed asset';
  end if;

  insert into public.asset_transfer_entries(
    asset_id, transfer_date, from_location, to_location, from_warehouse_id, to_warehouse_id, reason, created_by
  )
  values (
    p_asset_id,
    p_transfer_date,
    v_asset.location,
    v_new_location,
    v_asset.warehouse_id,
    p_new_warehouse_id,
    nullif(trim(coalesce(p_reason, '')), ''),
    auth.uid()
  );

  update public.fixed_assets
  set location = v_new_location,
      warehouse_id = p_new_warehouse_id,
      updated_at = now()
  where id = p_asset_id;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'fixed_assets.transfer',
    'fixed_assets',
    p_asset_id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'assetId', p_asset_id,
      'fromLocation', v_asset.location,
      'toLocation', v_new_location,
      'fromWarehouseId', v_asset.warehouse_id,
      'toWarehouseId', p_new_warehouse_id,
      'transferDate', p_transfer_date,
      'reason', nullif(trim(coalesce(p_reason, '')), '')
    ),
    'MEDIUM',
    'ASSET_TRANSFER'
  );

  return jsonb_build_object(
    'success', true,
    'assetId', p_asset_id::text,
    'fromLocation', coalesce(v_asset.location, ''),
    'toLocation', v_new_location
  );
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

revoke all on function public.post_asset_impairment(uuid, numeric, text, date) from public;
grant execute on function public.post_asset_impairment(uuid, numeric, text, date) to authenticated;
revoke all on function public.transfer_fixed_asset(uuid, text, uuid, text, date) from public;
grant execute on function public.transfer_fixed_asset(uuid, text, uuid, text, date) to authenticated;
revoke all on function public.get_fixed_assets_summary() from public;
grant execute on function public.get_fixed_assets_summary() to authenticated;

notify pgrst, 'reload schema';
