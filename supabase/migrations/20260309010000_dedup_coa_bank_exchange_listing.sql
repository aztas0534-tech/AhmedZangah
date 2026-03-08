set app.allow_ledger_ddl = '1';

create or replace function public.list_chart_of_accounts(p_include_inactive boolean default true)
returns table(
  id uuid,
  code text,
  name text,
  account_type text,
  normal_balance text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_permission('accounting.view') then
    raise exception 'not allowed';
  end if;

  return query
  with src as (
    select
      coa.*,
      regexp_replace(lower(btrim(coalesce(coa.name, ''))), '\s+', ' ', 'g') as name_key,
      (
        coa.code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR)$'
        or coa.code ~ '^(1020|1030)-[0-9]{3}-(AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$'
      ) as is_canonical_bank_code,
      (
        coa.code ~ '^(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)-(1020|1030)-[0-9]{3}$'
      ) as is_prefixed_bank_code,
      (
        coa.code ~ '^(1020|1030)\.[0-9]+$'
      ) as is_dot_bank_code,
      (
        coa.code ~ '^(1020|1030)(-|\.|$)'
        or coa.code ~ '^(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)-(1020|1030)-'
      ) as is_bank_exchange_family
    from public.chart_of_accounts coa
    where p_include_inactive = true or coa.is_active = true
  ),
  ranked as (
    select
      s.*,
      row_number() over (
        partition by
          case
            when s.is_bank_exchange_family then
              concat(s.name_key, '|', s.account_type, '|', s.normal_balance)
            else
              s.id::text
          end
        order by
          case
            when s.is_canonical_bank_code then 1
            when s.is_prefixed_bank_code then 2
            when s.is_dot_bank_code then 3
            else 4
          end asc,
          s.is_active desc,
          s.created_at asc,
          s.id asc
      ) as rn
    from src s
  )
  select
    r.id,
    r.code,
    r.name,
    r.account_type,
    r.normal_balance,
    r.is_active,
    r.created_at
  from ranked r
  where r.rn = 1
  order by r.code asc;
end;
$$;

revoke all on function public.list_chart_of_accounts(boolean) from public;
grant execute on function public.list_chart_of_accounts(boolean) to authenticated;

notify pgrst, 'reload schema';
