-- Aggregate sales by original currency (from journal_entries linked to orders)
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
  return query
  with effective_orders as (
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (p_zone_id is null or o.zone_id = p_zone_id)
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
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
         je.account_code like '4%' -- Sales / Revenue accounts (Credit normal balance)
      or je.account_code = '2210' -- Output VAT (Optional: usually we want just Revenue. If we want gross collected, we include VAT)
   )
  group by coalesce(je.currency_code, 'SAR')
  order by total_base_amount desc;

end;
$$;

revoke all on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) from public;
revoke execute on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) from anon;
grant execute on function public.get_sales_by_currency(timestamptz, timestamptz, uuid, boolean) to authenticated;
