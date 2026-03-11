-- ═══════════════════════════════════════════════════════════════
-- FIX: Rewrite get_product_sales_report wrapper to:
-- 1. Delegate to v10 (which delegates to v9)
-- 2. Apply FX conversion so all amounts are in base currency
-- 3. Ensure correct column names match frontend expectations
-- ═══════════════════════════════════════════════════════════════

-- Drop old wrapper signatures to avoid overload conflicts
do $$
begin
  drop function if exists public.get_product_sales_report(timestamptz, timestamptz, uuid);
  drop function if exists public.get_product_sales_report(timestamptz, timestamptz, text);
exception when others then null;
<<<<<<< HEAD
end $$
=======
end $$;

>>>>>>> 08c571d75d7ee9a6ad9bb1f7d6fa9268d94cae2a
create or replace function public.get_product_sales_report(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_zone_id uuid default null
)
returns table (
  item_id text,
  product_name text,
  item_name jsonb,
  unit_type text,
  quantity_sold numeric,
  total_qty_sold numeric,
  total_sales numeric,
  total_cost numeric,
  total_cogs numeric,
  total_profit numeric,
  current_stock numeric,
  reserved_stock numeric,
  current_cost_price numeric,
  avg_inventory numeric
)
language sql
security definer
set search_path = public
as $$
  select
    v.item_id,
    coalesce(
      v.item_name->>'ar',
      v.item_name->>'en',
      v.item_id
    ) as product_name,
    v.item_name,
    v.unit_type,
    v.quantity_sold,
    v.quantity_sold as total_qty_sold,
    v.total_sales,
    v.total_cost,
    v.total_cost as total_cogs,
    v.total_profit,
    v.current_stock,
    v.reserved_stock,
    v.current_cost_price,
    v.avg_inventory
  from public.get_product_sales_report_v10(
    p_start_date,
    p_end_date,
    p_zone_id,
    false
  ) v
  order by v.total_sales desc;
<<<<<<< HEAD
$$
revoke all on function public.get_product_sales_report(timestamptz, timestamptz, uuid) from public
revoke execute on function public.get_product_sales_report(timestamptz, timestamptz, uuid) from anon
grant execute on function public.get_product_sales_report(timestamptz, timestamptz, uuid) to authenticated
notify pgrst, 'reload schema'
=======
$$;

revoke all on function public.get_product_sales_report(timestamptz, timestamptz, uuid) from public;
revoke execute on function public.get_product_sales_report(timestamptz, timestamptz, uuid) from anon;
grant execute on function public.get_product_sales_report(timestamptz, timestamptz, uuid) to authenticated;

notify pgrst, 'reload schema';
>>>>>>> 08c571d75d7ee9a6ad9bb1f7d6fa9268d94cae2a
