create or replace function public.get_inventory_stock_report(
  p_warehouse_id uuid,
  p_category text default null,
  p_group text default null,
  p_supplier_id uuid default null,
  p_stock_filter text default 'all',
  p_search text default null,
  p_limit integer default 200,
  p_offset integer default 0
)
returns table (
  item_id text,
  item_name jsonb,
  category text,
  item_group text,
  unit text,
  current_stock numeric,
  reserved_stock numeric,
  available_stock numeric,
  low_stock_threshold numeric,
  supplier_ids uuid[],
  total_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer := greatest(1, coalesce(p_limit, 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  if not public.can_view_reports() then
    raise exception 'ليس لديك صلاحية عرض التقارير';
  end if;

  return query
  with stock_agg as (
    select
      sm.item_id::text as item_id,
      coalesce(sum(sm.available_quantity), 0) as current_stock,
      coalesce(sum(sm.reserved_quantity), 0) as reserved_stock,
      max(coalesce(sm.unit, 'piece')) as unit,
      max(coalesce(sm.low_stock_threshold, 5)) as low_stock_threshold
    from public.stock_management sm
    where (p_warehouse_id is null or sm.warehouse_id = p_warehouse_id)
    group by sm.item_id::text
  ),
  suppliers_agg as (
    select
      si.item_id::text as item_id,
      coalesce(array_agg(distinct si.supplier_id) filter (where si.is_active), '{}'::uuid[]) as supplier_ids
    from public.supplier_items si
    group by si.item_id::text
  ),
  base as (
    select
      mi.id as item_id,
      mi.name as item_name,
      mi.category as category,
      nullif(coalesce(mi.data->>'group', ''), '') as item_group,
      coalesce(sa.unit, coalesce(mi.base_unit, coalesce(mi.unit_type, 'piece'))) as unit,
      coalesce(sa.current_stock, 0) as current_stock,
      coalesce(sa.reserved_stock, 0) as reserved_stock,
      coalesce(sa.current_stock, 0) - coalesce(sa.reserved_stock, 0) as available_stock,
      coalesce(sa.low_stock_threshold, 5) as low_stock_threshold,
      coalesce(sup.supplier_ids, '{}'::uuid[]) as supplier_ids
    from public.menu_items mi
    left join stock_agg sa on sa.item_id = mi.id::text
    left join suppliers_agg sup on sup.item_id = mi.id::text
    where coalesce(mi.status, 'active') = 'active'
  ),
  filtered as (
    select b.*
    from base b
    where (p_category is null or p_category = '' or b.category = p_category)
      and (p_group is null or p_group = '' or b.item_group = p_group)
      and (p_supplier_id is null or p_supplier_id = any(b.supplier_ids))
      and (
        p_search is null or btrim(p_search) = ''
        or b.item_id ilike '%' || btrim(p_search) || '%'
        or coalesce(b.item_name->>'ar', '') ilike '%' || btrim(p_search) || '%'
        or coalesce(b.item_name->>'en', '') ilike '%' || btrim(p_search) || '%'
      )
      and (
        coalesce(p_stock_filter, 'all') = 'all'
        or (p_stock_filter = 'in' and b.available_stock > b.low_stock_threshold)
        or (p_stock_filter = 'low' and b.available_stock > 0 and b.available_stock <= b.low_stock_threshold)
        or (p_stock_filter = 'out' and b.available_stock <= 0)
      )
  ),
  counted as (
    select f.*, count(*) over ()::integer as total_count
    from filtered f
  )
  select *
  from counted
  order by available_stock asc, item_id asc
  limit v_limit
  offset v_offset;
end;
$$;

revoke all on function public.get_inventory_stock_report(uuid, text, text, uuid, text, text, integer, integer) from public;
grant execute on function public.get_inventory_stock_report(uuid, text, text, uuid, text, text, integer, integer) to authenticated;

notify pgrst, 'reload schema';

