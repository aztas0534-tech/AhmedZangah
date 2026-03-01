-- Multi-Currency Balances Report RPC

set app.allow_ledger_ddl = '1';

create or replace function public.currency_balances(
  p_start date,
  p_end date,
  p_cost_center_id uuid default null,
  p_journal_id uuid default null
)
returns table(
  account_code text,
  account_name text,
  account_type text,
  normal_balance text,
  currency_code text,
  total_debit numeric,
  total_credit numeric,
  balance numeric,
  base_total_debit numeric,
  base_total_credit numeric,
  base_balance numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base_currency text;
begin
  if not public.can_view_accounting_reports() then
    raise exception 'not allowed';
  end if;

  v_base_currency := public.get_base_currency();

  return query
  with raw_lines as (
    select
      jl.account_id,
      upper(coalesce(nullif(trim(jl.currency_code), ''), v_base_currency)) as rep_currency,
      case 
        when coalesce(jl.debit, 0) > 0 then coalesce(jl.foreign_amount, jl.debit)
        else 0
      end as f_debit,
      case 
        when coalesce(jl.credit, 0) > 0 then coalesce(jl.foreign_amount, jl.credit)
        else 0
      end as f_credit,
      coalesce(jl.debit, 0) as b_debit,
      coalesce(jl.credit, 0) as b_credit
    from public.journal_entries je
    join public.journal_lines jl
      on jl.journal_entry_id = je.id
    where (p_start is null or je.entry_date::date >= p_start)
      and (p_end is null or je.entry_date::date <= p_end)
      and (p_journal_id is null or je.journal_id = p_journal_id)
      and (p_cost_center_id is null or jl.cost_center_id = p_cost_center_id)
  ),
  grouped_lines as (
    select
      rl.account_id,
      rl.rep_currency,
      coalesce(sum(rl.f_debit), 0) as total_debit,
      coalesce(sum(rl.f_credit), 0) as total_credit,
      coalesce(sum(rl.b_debit), 0) as base_total_debit,
      coalesce(sum(rl.b_credit), 0) as base_total_credit
    from raw_lines rl
    group by rl.account_id, rl.rep_currency
  )
  select
    coa.code as account_code,
    coa.name as account_name,
    coa.account_type,
    coa.normal_balance,
    gl.rep_currency as currency_code,
    gl.total_debit,
    gl.total_credit,
    case
      when coa.normal_balance = 'debit' then gl.total_debit - gl.total_credit
      else gl.total_credit - gl.total_debit
    end as balance,
    gl.base_total_debit,
    gl.base_total_credit,
    case
      when coa.normal_balance = 'debit' then gl.base_total_debit - gl.base_total_credit
      else gl.base_total_credit - gl.base_total_debit
    end as base_balance
  from grouped_lines gl
  join public.chart_of_accounts coa
    on coa.id = gl.account_id
  where abs(gl.total_debit - gl.total_credit) > 1e-6 
     or abs(gl.base_total_debit - gl.base_total_credit) > 1e-6
     or abs(gl.total_debit) > 1e-6 
     or abs(gl.total_credit) > 1e-6
  order by coa.code, gl.rep_currency;
end;
$$;

revoke all on function public.currency_balances(date, date, uuid, uuid) from public;
revoke execute on function public.currency_balances(date, date, uuid, uuid) from anon;
grant execute on function public.currency_balances(date, date, uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
