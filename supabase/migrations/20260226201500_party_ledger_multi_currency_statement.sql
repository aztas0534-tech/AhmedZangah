set app.allow_ledger_ddl = '1';

create or replace function public.party_ledger_statement_v2(
  p_party_id uuid,
  p_account_code text default null,
  p_currency text default null,
  p_start date default null,
  p_end date default null
)
returns table(
  occurred_at timestamptz,
  journal_entry_id uuid,
  journal_line_id uuid,
  account_code text,
  account_name text,
  direction text,
  foreign_amount numeric,
  base_amount numeric,
  currency_code text,
  fx_rate numeric,
  memo text,
  source_table text,
  source_id text,
  source_event text,
  running_balance numeric,
  open_base_amount numeric,
  open_foreign_amount numeric,
  open_status text,
  allocations jsonb,
  account_normal_balance text,
  running_foreign_balance numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with acct as (
    select coa.id
    from public.chart_of_accounts coa
    where p_account_code is null or coa.code = p_account_code
  ),
  base as (
    select
      ple.occurred_at,
      ple.journal_entry_id,
      ple.journal_line_id,
      coa.code as account_code,
      coa.name as account_name,
      ple.direction,
      ple.foreign_amount,
      ple.base_amount,
      ple.currency_code,
      ple.fx_rate,
      jl.line_memo as memo,
      je.source_table,
      je.source_id,
      je.source_event,
      ple.running_balance,
      coa.normal_balance as account_normal_balance,
      sum(
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
      ) over (
        partition by ple.party_id, ple.account_id, ple.currency_code
        order by ple.occurred_at asc, ple.journal_entry_id asc, ple.journal_line_id asc
        rows between unbounded preceding and current row
      ) as running_foreign_balance
    from public.party_ledger_entries ple
    join public.journal_entries je on je.id = ple.journal_entry_id
    join public.journal_lines jl on jl.id = ple.journal_line_id
    join public.chart_of_accounts coa on coa.id = ple.account_id
    where public.has_admin_permission('accounting.view')
      and ple.party_id = p_party_id
      and (p_currency is null or upper(ple.currency_code) = upper(p_currency))
      and (p_start is null or ple.occurred_at::date >= p_start)
      and (p_end is null or ple.occurred_at::date <= p_end)
      and (p_account_code is null or ple.account_id in (select id from acct))
  ),
  alloc as (
    select
      poi.journal_line_id,
      jsonb_agg(
        jsonb_build_object(
          'settlementId', sl.settlement_id::text,
          'fromOpenItemId', sl.from_open_item_id::text,
          'toOpenItemId', sl.to_open_item_id::text,
          'allocatedBase', sl.allocated_base_amount,
          'allocatedCounterBase', sl.allocated_counter_base_amount,
          'allocatedForeign', sl.allocated_foreign_amount,
          'realizedFx', sl.realized_fx_amount
        )
        order by sl.created_at asc
      ) as allocations
    from public.party_open_items poi
    join public.settlement_lines sl
      on sl.from_open_item_id = poi.id or sl.to_open_item_id = poi.id
    group by poi.journal_line_id
  )
  select
    b.occurred_at,
    b.journal_entry_id,
    b.journal_line_id,
    b.account_code,
    b.account_name,
    b.direction,
    b.foreign_amount,
    b.base_amount,
    b.currency_code,
    b.fx_rate,
    b.memo,
    b.source_table,
    b.source_id,
    b.source_event,
    b.running_balance,
    poi.open_base_amount,
    poi.open_foreign_amount,
    poi.status as open_status,
    coalesce(a.allocations, '[]'::jsonb) as allocations,
    b.account_normal_balance,
    b.running_foreign_balance
  from base b
  left join public.party_open_items poi on poi.journal_line_id = b.journal_line_id
  left join alloc a on a.journal_line_id = b.journal_line_id
  order by b.occurred_at asc, b.journal_entry_id asc, b.journal_line_id asc;
$$;

revoke all on function public.party_ledger_statement_v2(uuid, text, text, date, date) from public;
grant execute on function public.party_ledger_statement_v2(uuid, text, text, date, date) to authenticated;

notify pgrst, 'reload schema';

