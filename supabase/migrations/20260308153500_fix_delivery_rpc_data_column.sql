-- Fix: column "data" does not exist error in confirm_order_delivery_rpc
-- Root cause: The _rpc alias functions read o.data from orders but
-- the orders table may not yet have the data column on production.
-- Solution: Ensure the data column exists AND rewrite the _rpc aliases
-- as simple pass-through wrappers.

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
end
$$;

----------------------------------------------------------------------
-- 2. Recreate confirm_order_delivery_rpc as a simple wrapper
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
-- 3. Recreate confirm_order_delivery_with_credit_rpc as a simple wrapper
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
-- 4. Reload PostgREST schema cache
----------------------------------------------------------------------
select pg_sleep(0.5);
notify pgrst, 'reload schema';
