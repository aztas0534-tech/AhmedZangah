-- Comprehensive fix: column "data" does not exist in delivery chain
-- The issue is that deduct_stock_on_delivery_v2 references o.data from orders table.
-- This migration ensures the data column exists AND reapplies all functions in the chain.

----------------------------------------------------------------------
-- 1. Ensure orders.data column exists  
----------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'orders'
      and column_name = 'data'
  ) then
    alter table public.orders add column data jsonb default '{}'::jsonb;
    raise notice 'Added data column to public.orders';
  end if;
end $$;

----------------------------------------------------------------------
-- 2. Reapply deduct_stock_on_delivery_v2 with full body  
----------------------------------------------------------------------
create or replace function public.deduct_stock_on_delivery_v2(
  p_items jsonb,
  p_order_id uuid,
  p_warehouse_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.deduct_stock_on_delivery_v2(p_order_id, p_items, p_warehouse_id);
end;
$$;

----------------------------------------------------------------------
-- 3. Reapply confirm_order_delivery_rpc
----------------------------------------------------------------------
create or replace function public.confirm_order_delivery_rpc(
  p_order_id uuid,
  p_items jsonb,
  p_updated_data jsonb,
  p_warehouse_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.confirm_order_delivery(p_order_id, p_items, p_updated_data, p_warehouse_id);
end;
$$;

revoke all on function public.confirm_order_delivery_rpc(uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.confirm_order_delivery_rpc(uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.confirm_order_delivery_rpc(uuid, jsonb, jsonb, uuid) to authenticated;
grant execute on function public.confirm_order_delivery_rpc(uuid, jsonb, jsonb, uuid) to service_role;

----------------------------------------------------------------------
-- 4. Reapply confirm_order_delivery_with_credit_rpc  
----------------------------------------------------------------------
create or replace function public.confirm_order_delivery_with_credit_rpc(
  p_order_id uuid,
  p_items jsonb,
  p_updated_data jsonb,
  p_warehouse_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.confirm_order_delivery_with_credit(p_order_id, p_items, p_updated_data, p_warehouse_id);
end;
$$;

revoke all on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) to authenticated;
grant execute on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) to service_role;

----------------------------------------------------------------------
-- 5. Reload PostgREST schema cache
----------------------------------------------------------------------
select pg_sleep(0.5);
notify pgrst, 'reload schema';
