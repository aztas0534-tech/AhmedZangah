-- Fix get_sales_by_currency: o.zone_id -> delivery_zone_id pattern, 
-- o.invoice_number doesn't exist, use invoiceSnapshot instead
-- Also add is_staff() check and grant to authenticated

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
    coalesce(je.currency_code, 'SAR') as currency_code,
    sum(coalesce(je.foreign_amount, je.credit)) as total_foreign_amount,
    sum(je.credit) as total_base_amount,
    count(distinct eo.id)::integer as order_count
  from effective_orders eo
  join public.journal_entries je
    on je.source_table = 'orders'
   and je.source_id = eo.id::text
   and je.credit > 0
   and (
         je.account_code like '4%'
      or je.account_code = '2210'
   )
  group by coalesce(je.currency_code, 'SAR')
  order by total_base_amount desc;

end;
$$;

revoke all on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) from public;
grant execute on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
