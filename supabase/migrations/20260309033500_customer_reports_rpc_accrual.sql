set app.allow_ledger_ddl = '1';

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
