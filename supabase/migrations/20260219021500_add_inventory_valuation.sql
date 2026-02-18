-- ============================================================================
-- Migration: Add Inventory Valuation RPC
-- Date: 2026-02-19
-- Purpose: Get total value of available inventory for Dashboard KPI
-- ============================================================================

create or replace function public.get_inventory_valuation(
  p_warehouse_id uuid default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Check permission (using same check as other reports)
  if not public.can_view_reports() then
     -- Fallback for safety if function doesn't exist or logic differs, 
     -- but usually this is standard. 
     -- If this fails, we can remove it or rely on RLS, but RPCs bypass RLS unless 'security invoker'.
     -- We stick to 'security definer' + explicit check as per existing pattern.
    raise exception 'ليس لديك صلاحية عرض التقارير';
  end if;

  return (
    select coalesce(sum(
      sm.available_quantity * coalesce(sm.avg_cost, mi.cost_price, 0)
    ), 0)
    from public.stock_management sm
    join public.menu_items mi on mi.id = sm.item_id
    where (p_warehouse_id is null or sm.warehouse_id = p_warehouse_id)
      and sm.available_quantity > 0
  );
end;
$$;

revoke all on function public.get_inventory_valuation(uuid) from public;
grant execute on function public.get_inventory_valuation(uuid) to authenticated;
