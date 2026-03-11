set app.allow_ledger_ddl = '1';

create or replace function public.get_sales_by_currency(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_zone_id uuid default null,
  p_invoice_only boolean default false
)
returns table (
  currency_code text,
  total_foreign_amount numeric,
  total_base_amount numeric,
  order_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text := upper(public.get_base_currency());
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;

  return query
  with effective_orders as (
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (p_zone_id is null or coalesce(
        o.delivery_zone_id,
        case
          when nullif(o.data->>'deliveryZoneId','') is not null
               and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (o.data->>'deliveryZoneId')::uuid
          else null
        end
      ) = p_zone_id)
      and (not p_invoice_only or nullif(o.data->'invoiceSnapshot'->>'issuedAt', '') is not null)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  )
  select
    coalesce(nullif(upper(jl.currency_code), ''), v_base) as currency_code,
    sum(
      case
        when jl.currency_code is not null
             and upper(jl.currency_code) <> v_base
             and jl.foreign_amount is not null
             and jl.credit > 0
          then abs(jl.foreign_amount)
        else coalesce(jl.credit, 0)
      end
    ) as total_foreign_amount,
    sum(coalesce(jl.credit, 0)) as total_base_amount,
    count(distinct eo.id)::integer as order_count
  from effective_orders eo
  join public.journal_entries je
    on je.source_table = 'orders'
   and je.source_id = eo.id::text
  join public.journal_lines jl
    on jl.journal_entry_id = je.id
   and jl.credit > 0
  join public.chart_of_accounts coa
    on coa.id = jl.account_id
   and (coa.code like '4%' or coa.code = '2210')
  group by coalesce(nullif(upper(jl.currency_code), ''), v_base)
  order by total_base_amount desc;
end;
$$;

revoke all on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) from public;
revoke execute on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) from anon;
grant execute on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) to authenticated;

create or replace function public.get_customer_sales_report_v1(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_invoice_only boolean default false
)
returns table(
  customer_auth_user_id uuid,
  total_orders bigint,
  total_spent numeric,
  avg_order_value numeric,
  last_order_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;

  return query
  with effective_orders as (
    select
      o.customer_auth_user_id,
      o.status,
      nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
      case
        when p_invoice_only
          then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
        else coalesce(
          nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
          nullif(o.data->>'paidAt', '')::timestamptz,
          nullif(o.data->>'deliveredAt', '')::timestamptz,
          o.created_at
        )
      end as date_by,
      coalesce(
        o.base_total,
        coalesce(nullif((o.data->>'total')::numeric, null), 0) * public.order_fx_rate(
          coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
          case
            when p_invoice_only
              then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
            else coalesce(
              nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
              nullif(o.data->>'paidAt', '')::timestamptz,
              nullif(o.data->>'deliveredAt', '')::timestamptz,
              o.created_at
            )
          end,
          o.fx_rate
        )
      ) as total
    from public.orders o
    where o.customer_auth_user_id is not null
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  )
  select
    eo.customer_auth_user_id,
    count(*)::bigint as total_orders,
    coalesce(sum(eo.total), 0) as total_spent,
    case when count(*) > 0 then coalesce(sum(eo.total), 0) / count(*) else 0 end as avg_order_value,
    max(eo.date_by) as last_order_at
  from effective_orders eo
  where (eo.status = 'delivered' or eo.paid_at is not null)
    and eo.date_by >= p_start_date
    and eo.date_by <= p_end_date
  group by eo.customer_auth_user_id;
end;
$$;

revoke all on function public.get_customer_sales_report_v1(timestamptz, timestamptz, boolean) from public;
revoke execute on function public.get_customer_sales_report_v1(timestamptz, timestamptz, boolean) from anon;
grant execute on function public.get_customer_sales_report_v1(timestamptz, timestamptz, boolean) to authenticated;

notify pgrst, 'reload schema';
