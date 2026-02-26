set app.allow_ledger_ddl = '1';

-- ============================================================================
-- Per-currency aging report for AR and AP
-- Shows aging buckets broken down by currency for each party
-- ============================================================================

create or replace function public.party_ar_aging_by_currency(
  p_as_of date default current_date,
  p_party_id uuid default null
)
returns table (
  party_id uuid,
  party_name text,
  currency_code text,
  current_amount numeric,
  days_1_30 numeric,
  days_31_60 numeric,
  days_61_90 numeric,
  days_91_plus numeric,
  total_outstanding numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select
    poi.party_id,
    fp.name as party_name,
    poi.currency_code,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) <= 0 then poi.open_foreign_amount end), 0) as current_amount,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) between 1 and 30 then poi.open_foreign_amount end), 0) as days_1_30,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) between 31 and 60 then poi.open_foreign_amount end), 0) as days_31_60,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) between 61 and 90 then poi.open_foreign_amount end), 0) as days_61_90,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) > 90 then poi.open_foreign_amount end), 0) as days_91_plus,
    coalesce(sum(poi.open_foreign_amount), 0) as total_outstanding
  from public.party_open_items poi
  join public.financial_parties fp on fp.id = poi.party_id
  join public.chart_of_accounts coa on coa.id = poi.account_id
  join public.party_subledger_accounts psa on psa.account_id = poi.account_id and psa.role = 'ar'
  where public.has_admin_permission('accounting.view')
    and poi.status = 'open'
    and coalesce(poi.open_foreign_amount, 0) > 0.001
    and (p_party_id is null or poi.party_id = p_party_id)
  group by poi.party_id, fp.name, poi.currency_code
  having coalesce(sum(poi.open_foreign_amount), 0) > 0.001
  order by fp.name, poi.currency_code;
$$;

create or replace function public.party_ap_aging_by_currency(
  p_as_of date default current_date,
  p_party_id uuid default null
)
returns table (
  party_id uuid,
  party_name text,
  currency_code text,
  current_amount numeric,
  days_1_30 numeric,
  days_31_60 numeric,
  days_61_90 numeric,
  days_91_plus numeric,
  total_outstanding numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select
    poi.party_id,
    fp.name as party_name,
    poi.currency_code,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) <= 0 then poi.open_foreign_amount end), 0) as current_amount,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) between 1 and 30 then poi.open_foreign_amount end), 0) as days_1_30,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) between 31 and 60 then poi.open_foreign_amount end), 0) as days_31_60,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) between 61 and 90 then poi.open_foreign_amount end), 0) as days_61_90,
    coalesce(sum(case when (p_as_of - poi.occurred_at::date) > 90 then poi.open_foreign_amount end), 0) as days_91_plus,
    coalesce(sum(poi.open_foreign_amount), 0) as total_outstanding
  from public.party_open_items poi
  join public.financial_parties fp on fp.id = poi.party_id
  join public.chart_of_accounts coa on coa.id = poi.account_id
  join public.party_subledger_accounts psa on psa.account_id = poi.account_id and psa.role = 'ap'
  where public.has_admin_permission('accounting.view')
    and poi.status = 'open'
    and coalesce(poi.open_foreign_amount, 0) > 0.001
    and (p_party_id is null or poi.party_id = p_party_id)
  group by poi.party_id, fp.name, poi.currency_code
  having coalesce(sum(poi.open_foreign_amount), 0) > 0.001
  order by fp.name, poi.currency_code;
$$;

revoke all on function public.party_ar_aging_by_currency(date, uuid) from public;
revoke all on function public.party_ap_aging_by_currency(date, uuid) from public;
grant execute on function public.party_ar_aging_by_currency(date, uuid) to authenticated;
grant execute on function public.party_ap_aging_by_currency(date, uuid) to authenticated;

notify pgrst, 'reload schema';
