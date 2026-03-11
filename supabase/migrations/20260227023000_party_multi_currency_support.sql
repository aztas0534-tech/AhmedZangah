set app.allow_ledger_ddl = '1';

-- ============================================================================
-- 1. party_currencies — allows multiple currencies per party
-- ============================================================================
do $$
begin
  if to_regclass('public.party_currencies') is null then
    create table public.party_currencies (
      id uuid primary key default gen_random_uuid(),
      party_id uuid not null references public.financial_parties(id) on delete cascade,
      currency_code text not null,
      is_default boolean not null default false,
      created_at timestamptz not null default now(),
      created_by uuid references auth.users(id) on delete set null,
      unique (party_id, currency_code)
    );
    create index if not exists idx_party_currencies_party on public.party_currencies(party_id);
  end if;
end $$;

-- FK to currencies table if exists
do $$
begin
  if to_regclass('public.currencies') is not null then
    begin
      alter table public.party_currencies
        add constraint party_currencies_code_fk
        foreign key (currency_code) references public.currencies(code)
        on update cascade on delete restrict;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

alter table public.party_currencies enable row level security;

drop policy if exists party_currencies_select on public.party_currencies;
create policy party_currencies_select
on public.party_currencies for select
using (public.has_admin_permission('accounting.view'));

drop policy if exists party_currencies_write on public.party_currencies;
create policy party_currencies_write
on public.party_currencies for all
using (public.has_admin_permission('accounting.manage'))
with check (public.has_admin_permission('accounting.manage'));

-- Backfill from currency_preference
do $$
declare
  r record;
begin
  for r in
    select fp.id as party_id, upper(trim(fp.currency_preference)) as cur
    from public.financial_parties fp
    where fp.currency_preference is not null
      and trim(fp.currency_preference) <> ''
  loop
    insert into public.party_currencies(party_id, currency_code, is_default)
    values (r.party_id, r.cur, true)
    on conflict (party_id, currency_code) do update set is_default = true;
  end loop;
end $$;

-- Also backfill from actual ledger usage (parties with entries in currencies they don't have registered)
do $$
declare
  r record;
begin
  for r in
    select distinct ple.party_id, upper(ple.currency_code) as cur
    from public.party_ledger_entries ple
    where ple.currency_code is not null
      and trim(ple.currency_code) <> ''
      and not exists (
        select 1 from public.party_currencies pc
        where pc.party_id = ple.party_id and upper(pc.currency_code) = upper(ple.currency_code)
      )
  loop
    insert into public.party_currencies(party_id, currency_code, is_default)
    values (r.party_id, r.cur, false)
    on conflict (party_id, currency_code) do nothing;
  end loop;
end $$;

-- ============================================================================
-- 2. get_party_balance_by_currency — summary of balances per currency
-- ============================================================================
create or replace function public.get_party_balance_by_currency(
  p_party_id uuid
)
returns table (
  currency_code text,
  account_code text,
  account_name text,
  foreign_balance numeric,
  base_balance numeric,
  last_entry_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    ple.currency_code,
    coa.code as account_code,
    coa.name as account_name,
    coalesce(sum(
      case
        when coalesce(coa.normal_balance, 'debit') = 'debit' then
          case when ple.direction = 'debit'
            then coalesce(ple.foreign_amount, ple.base_amount)
            else -coalesce(ple.foreign_amount, ple.base_amount)
          end
        else
          case when ple.direction = 'credit'
            then coalesce(ple.foreign_amount, ple.base_amount)
            else -coalesce(ple.foreign_amount, ple.base_amount)
          end
      end
    ), 0) as foreign_balance,
    coalesce(sum(
      case
        when coalesce(coa.normal_balance, 'debit') = 'debit' then
          case when ple.direction = 'debit' then ple.base_amount else -ple.base_amount end
        else
          case when ple.direction = 'credit' then ple.base_amount else -ple.base_amount end
      end
    ), 0) as base_balance,
    max(ple.occurred_at) as last_entry_at
  from public.party_ledger_entries ple
  join public.chart_of_accounts coa on coa.id = ple.account_id
  where public.has_admin_permission('accounting.view')
    and ple.party_id = p_party_id
    and ple.currency_code is not null
    and trim(ple.currency_code) <> ''
  group by ple.currency_code, coa.code, coa.name
  having abs(coalesce(sum(
    case
      when coalesce(coa.normal_balance, 'debit') = 'debit' then
        case when ple.direction = 'debit'
          then coalesce(ple.foreign_amount, ple.base_amount)
          else -coalesce(ple.foreign_amount, ple.base_amount)
        end
      else
        case when ple.direction = 'credit'
          then coalesce(ple.foreign_amount, ple.base_amount)
          else -coalesce(ple.foreign_amount, ple.base_amount)
        end
    end
  ), 0)) > 0.001
  order by ple.currency_code, coa.code;
$$;

revoke all on function public.get_party_balance_by_currency(uuid) from public;
grant execute on function public.get_party_balance_by_currency(uuid) to authenticated;

-- ============================================================================
-- 3. ensure_party_currency — auto-register currency when used in a transaction
-- ============================================================================
create or replace function public.ensure_party_currency(
  p_party_id uuid,
  p_currency_code text,
  p_is_default boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cur text;
begin
  if p_party_id is null or p_currency_code is null then return; end if;
  v_cur := upper(trim(p_currency_code));
  if v_cur = '' then return; end if;

  insert into public.party_currencies(party_id, currency_code, is_default)
  values (p_party_id, v_cur, coalesce(p_is_default, false))
  on conflict (party_id, currency_code) do nothing;
end;
$$;

notify pgrst, 'reload schema';
