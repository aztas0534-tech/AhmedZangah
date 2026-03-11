do $$
begin
  if to_regclass('public.financial_parties') is not null then
    alter table public.financial_parties
      add column if not exists credit_limit_base numeric not null default 0;
    alter table public.financial_parties
      add column if not exists credit_net_days integer not null default 30;
    alter table public.financial_parties
      add column if not exists credit_hold boolean not null default false;
  end if;
end $$;

do $$
begin
  if to_regclass('public.party_credit_overrides') is null then
    create table public.party_credit_overrides (
      id uuid primary key default gen_random_uuid(),
      party_id uuid not null references public.financial_parties(id) on delete restrict,
      order_id uuid not null references public.orders(id) on delete restrict,
      net_ar_base numeric not null,
      current_balance_base numeric not null,
      credit_limit_base numeric not null,
      reason text not null,
      approved_by uuid references auth.users(id) on delete set null,
      approved_at timestamptz not null default now(),
      created_at timestamptz not null default now()
    );
    create index if not exists idx_party_credit_overrides_party on public.party_credit_overrides(party_id, approved_at desc);
    create index if not exists idx_party_credit_overrides_order on public.party_credit_overrides(order_id);
  end if;
end $$;

alter table public.party_credit_overrides enable row level security;

drop policy if exists party_credit_overrides_select on public.party_credit_overrides;
create policy party_credit_overrides_select on public.party_credit_overrides
for select using (public.has_admin_permission('accounting.view'));

drop policy if exists party_credit_overrides_insert on public.party_credit_overrides;
create policy party_credit_overrides_insert on public.party_credit_overrides
for insert with check (public.has_admin_permission('accounting.manage'));

drop policy if exists party_credit_overrides_update_none on public.party_credit_overrides;
create policy party_credit_overrides_update_none on public.party_credit_overrides
for update using (false);

drop policy if exists party_credit_overrides_delete_none on public.party_credit_overrides;
create policy party_credit_overrides_delete_none on public.party_credit_overrides
for delete using (false);

create or replace function public.compute_party_ar_balance(p_party_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with ar as (
    select public.get_account_id_by_code('1200') as ar_id
  )
  select coalesce(sum(
    case
      when poi.direction = 'debit' then coalesce(poi.open_base_amount, poi.base_amount, 0)
      else -coalesce(poi.open_base_amount, poi.base_amount, 0)
    end
  ), 0)
  from public.party_open_items poi
  join ar on poi.account_id = ar.ar_id
  where poi.party_id = p_party_id
    and poi.status in ('open','partially_settled');
$$;

revoke all on function public.compute_party_ar_balance(uuid) from public;
revoke execute on function public.compute_party_ar_balance(uuid) from anon;
grant execute on function public.compute_party_ar_balance(uuid) to authenticated;

create or replace function public.get_party_credit_summary(p_party_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party record;
  v_balance numeric := 0;
  v_available numeric := 0;
begin
  if not public.has_admin_permission('accounting.view') then
    raise exception 'not allowed';
  end if;

  select p.*
  into v_party
  from public.financial_parties p
  where p.id = p_party_id;

  if not found then
    return json_build_object('exists', false);
  end if;

  v_balance := public.compute_party_ar_balance(p_party_id);
  v_available := greatest(coalesce(v_party.credit_limit_base, 0) - greatest(v_balance, 0), 0);

  return json_build_object(
    'exists', true,
    'party_mode', true,
    'party_id', p_party_id,
    'party_type', v_party.party_type,
    'is_active', v_party.is_active,
    'credit_hold', coalesce(v_party.credit_hold, false),
    'credit_limit', coalesce(v_party.credit_limit_base, 0),
    'current_balance', v_balance,
    'available_credit', v_available,
    'net_days_default', coalesce(v_party.credit_net_days, 30)
  );
end;
$$;

revoke all on function public.get_party_credit_summary(uuid) from public;
revoke execute on function public.get_party_credit_summary(uuid) from anon;
grant execute on function public.get_party_credit_summary(uuid) to authenticated;

create or replace function public.check_party_credit_limit(
  p_party_id uuid,
  p_order_amount_base numeric
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit numeric := 0;
  v_hold boolean := false;
  v_is_active boolean := true;
  v_balance numeric := 0;
begin
  if p_party_id is null then
    return true;
  end if;

  select coalesce(p.credit_limit_base, 0), coalesce(p.credit_hold, false), coalesce(p.is_active, true)
  into v_limit, v_hold, v_is_active
  from public.financial_parties p
  where p.id = p_party_id;

  if not found then
    return false;
  end if;

  if v_is_active = false then
    return false;
  end if;

  if v_hold then
    return coalesce(p_order_amount_base, 0) <= 0;
  end if;

  if v_limit <= 0 then
    return coalesce(p_order_amount_base, 0) <= 0;
  end if;

  v_balance := public.compute_party_ar_balance(p_party_id);

  return (greatest(v_balance, 0) + greatest(coalesce(p_order_amount_base, 0), 0)) <= v_limit;
end;
$$;

revoke all on function public.check_party_credit_limit(uuid, numeric) from public;
revoke execute on function public.check_party_credit_limit(uuid, numeric) from anon;
grant execute on function public.check_party_credit_limit(uuid, numeric) to authenticated;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
