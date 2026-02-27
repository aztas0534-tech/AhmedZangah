set app.allow_ledger_ddl = '1';

-- ============================================================================
-- Multi-Currency Credit Limits
--
-- Previously: credit_limit_base was a single numeric on financial_parties (base currency only).
-- Now: party_credit_limits table allows per-currency credit limits.
--
-- Example:
--   Party "أحمد"
--     SAR: credit_limit = 50,000  (رصيد 30,000 → متاح 20,000)
--     USD: credit_limit = 2,000   (رصيد 500 → متاح 1,500)
--
-- The old credit_limit_base on financial_parties is kept as the DEFAULT
-- base-currency fallback if no per-currency row exists.
-- ============================================================================

-- 1. Per-currency credit limits table
do $$
begin
  if to_regclass('public.party_credit_limits') is null then
    create table public.party_credit_limits (
      id uuid primary key default gen_random_uuid(),
      party_id uuid not null references public.financial_parties(id) on delete restrict,
      currency_code text not null,
      credit_limit numeric not null default 0,
      credit_hold boolean not null default false,
      net_days integer not null default 30,
      created_at timestamptz not null default now(),
      updated_at timestamptz not null default now(),
      unique (party_id, currency_code)
    );
    create index if not exists idx_party_credit_limits_party on public.party_credit_limits(party_id);
  end if;
end $$;

alter table public.party_credit_limits enable row level security;

drop policy if exists party_credit_limits_select on public.party_credit_limits;
create policy party_credit_limits_select on public.party_credit_limits
for select using (public.has_admin_permission('accounting.view'));

drop policy if exists party_credit_limits_write on public.party_credit_limits;
create policy party_credit_limits_write on public.party_credit_limits
for all using (public.has_admin_permission('accounting.manage'))
with check (public.has_admin_permission('accounting.manage'));

-- Auto-update updated_at
drop trigger if exists trg_party_credit_limits_updated_at on public.party_credit_limits;
create trigger trg_party_credit_limits_updated_at
before update on public.party_credit_limits
for each row execute function public.set_updated_at();

-- 2. Compute AR balance per currency (foreign_amount based)
create or replace function public.compute_party_ar_balance_by_currency(
  p_party_id uuid,
  p_currency_code text default null
)
returns table (currency_code text, ar_balance numeric)
language sql
stable
security definer
set search_path = public
as $$
  with ar as (
    select public.get_account_id_by_code('1200') as ar_id
  )
  select
    coalesce(poi.currency_code, public.get_base_currency()) as currency_code,
    coalesce(sum(
      case
        when poi.direction = 'debit' then coalesce(poi.open_foreign_amount, poi.open_base_amount, poi.base_amount, 0)
        else -coalesce(poi.open_foreign_amount, poi.open_base_amount, poi.base_amount, 0)
      end
    ), 0) as ar_balance
  from public.party_open_items poi
  join ar on poi.account_id = ar.ar_id
  where poi.party_id = p_party_id
    and poi.status in ('open','partially_settled')
    and (p_currency_code is null or coalesce(poi.currency_code, public.get_base_currency()) = upper(btrim(p_currency_code)))
  group by coalesce(poi.currency_code, public.get_base_currency());
$$;

revoke all on function public.compute_party_ar_balance_by_currency(uuid, text) from public;
grant execute on function public.compute_party_ar_balance_by_currency(uuid, text) to authenticated;


-- 3. Updated get_party_credit_summary: returns per-currency breakdown
-- Replaces the old single-currency version
do $$
begin
  if to_regprocedure('public.get_party_credit_summary(uuid)') is not null then
    begin
      drop function public.get_party_credit_summary(uuid);
    exception when others then
      null;
    end;
  end if;
end $$;

create or replace function public.get_party_credit_summary(p_party_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party record;
  v_base text;
  v_base_balance numeric := 0;
  v_base_limit numeric := 0;
  v_base_available numeric := 0;
  v_currencies jsonb := '[]'::jsonb;
  v_rec record;
begin
  if not public.has_admin_permission('accounting.view') then
    raise exception 'not allowed';
  end if;

  select p.*
  into v_party
  from public.financial_parties p
  where p.id = p_party_id;

  if not found then
    return jsonb_build_object('exists', false);
  end if;

  v_base := public.get_base_currency();

  -- Base currency balance (backward compatible)
  v_base_balance := public.compute_party_ar_balance(p_party_id);
  v_base_limit := coalesce(v_party.credit_limit_base, 0);
  v_base_available := greatest(v_base_limit - greatest(v_base_balance, 0), 0);

  -- Per-currency breakdown
  for v_rec in
    select
      bal.currency_code,
      bal.ar_balance,
      coalesce(pcl.credit_limit, 
        case when bal.currency_code = v_base then v_base_limit else 0 end
      ) as credit_limit,
      coalesce(pcl.credit_hold,
        case when bal.currency_code = v_base then coalesce(v_party.credit_hold, false) else false end
      ) as credit_hold,
      coalesce(pcl.net_days,
        case when bal.currency_code = v_base then coalesce(v_party.credit_net_days, 30) else 30 end
      ) as net_days
    from public.compute_party_ar_balance_by_currency(p_party_id, null) bal
    left join public.party_credit_limits pcl
      on pcl.party_id = p_party_id and pcl.currency_code = bal.currency_code
    union all
    -- Include currencies with credit limits but no outstanding balance
    select
      pcl.currency_code,
      0 as ar_balance,
      pcl.credit_limit,
      pcl.credit_hold,
      pcl.net_days
    from public.party_credit_limits pcl
    where pcl.party_id = p_party_id
      and not exists (
        select 1 from public.compute_party_ar_balance_by_currency(p_party_id, null) bal
        where bal.currency_code = pcl.currency_code
      )
  loop
    v_currencies := v_currencies || jsonb_build_object(
      'currency_code', v_rec.currency_code,
      'current_balance', v_rec.ar_balance,
      'credit_limit', v_rec.credit_limit,
      'credit_hold', v_rec.credit_hold,
      'available_credit', greatest(v_rec.credit_limit - greatest(v_rec.ar_balance, 0), 0),
      'net_days', v_rec.net_days
    );
  end loop;

  return jsonb_build_object(
    'exists', true,
    'party_mode', true,
    'party_id', p_party_id,
    'party_type', v_party.party_type,
    'is_active', v_party.is_active,
    -- Backward compatible fields (base currency)
    'credit_hold', coalesce(v_party.credit_hold, false),
    'credit_limit', v_base_limit,
    'current_balance', v_base_balance,
    'available_credit', v_base_available,
    'net_days_default', coalesce(v_party.credit_net_days, 30),
    -- New: per-currency breakdown
    'currencies', v_currencies
  );
end;
$$;

revoke all on function public.get_party_credit_summary(uuid) from public;
grant execute on function public.get_party_credit_summary(uuid) to authenticated;


-- 4. Updated check_party_credit_limit to support per-currency check
create or replace function public.check_party_credit_limit(
  p_party_id uuid,
  p_order_amount_base numeric,
  p_currency_code text default null
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
  v_base text;
  v_currency text;
  v_pcl record;
begin
  if p_party_id is null then
    return true;
  end if;

  v_base := public.get_base_currency();
  v_currency := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  if v_currency is null or v_currency = '' then
    v_currency := v_base;
  end if;

  select coalesce(p.is_active, true) into v_is_active
  from public.financial_parties p
  where p.id = p_party_id;

  if not found then
    return false;
  end if;

  if v_is_active = false then
    return false;
  end if;

  -- Check per-currency limit first
  select pcl.* into v_pcl
  from public.party_credit_limits pcl
  where pcl.party_id = p_party_id and pcl.currency_code = v_currency;

  if found then
    -- Per-currency limit exists
    if v_pcl.credit_hold then
      return coalesce(p_order_amount_base, 0) <= 0;
    end if;
    v_limit := coalesce(v_pcl.credit_limit, 0);
    if v_limit <= 0 then
      return coalesce(p_order_amount_base, 0) <= 0;
    end if;
    -- Get balance in this currency
    select coalesce(bal.ar_balance, 0) into v_balance
    from public.compute_party_ar_balance_by_currency(p_party_id, v_currency) bal
    limit 1;
    return (greatest(v_balance, 0) + greatest(coalesce(p_order_amount_base, 0), 0)) <= v_limit;
  end if;

  -- Fallback to base-currency limit from financial_parties
  select coalesce(p.credit_limit_base, 0), coalesce(p.credit_hold, false)
  into v_limit, v_hold
  from public.financial_parties p
  where p.id = p_party_id;

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

revoke all on function public.check_party_credit_limit(uuid, numeric, text) from public;
grant execute on function public.check_party_credit_limit(uuid, numeric, text) to authenticated;


-- 5. Backward compatible: keep old 2-arg signature working
create or replace function public.check_party_credit_limit(
  p_party_id uuid,
  p_order_amount_base numeric
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.check_party_credit_limit(p_party_id, p_order_amount_base, null);
$$;

revoke all on function public.check_party_credit_limit(uuid, numeric) from public;
grant execute on function public.check_party_credit_limit(uuid, numeric) to authenticated;


-- ============================================================================
-- Migrate existing credit_limit_base to party_credit_limits (base currency)
-- ============================================================================
do $$
declare
  v_base text;
begin
  v_base := public.get_base_currency();
  insert into public.party_credit_limits (party_id, currency_code, credit_limit, credit_hold, net_days)
  select
    fp.id,
    v_base,
    fp.credit_limit_base,
    fp.credit_hold,
    fp.credit_net_days
  from public.financial_parties fp
  where fp.credit_limit_base > 0
  on conflict (party_id, currency_code) do update
  set credit_limit = excluded.credit_limit,
      credit_hold = excluded.credit_hold,
      net_days = excluded.net_days;
end $$;

notify pgrst, 'reload schema';
