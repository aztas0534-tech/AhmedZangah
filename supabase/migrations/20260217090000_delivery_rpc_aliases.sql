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
declare
  v_status text;
  v_data jsonb;
  v_updated_at timestamptz;
begin
  perform public.confirm_order_delivery(p_order_id, p_items, p_updated_data, p_warehouse_id);

  select o.status::text, o.data, o.updated_at
  into v_status, v_data, v_updated_at
  from public.orders o
  where o.id = p_order_id;

  return jsonb_build_object(
    'orderId', p_order_id::text,
    'status', coalesce(v_status, 'delivered'),
    'data', coalesce(v_data, '{}'::jsonb),
    'updatedAt', coalesce(v_updated_at, now())
  );
end;
$$;

revoke all on function public.confirm_order_delivery_rpc(uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.confirm_order_delivery_rpc(uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.confirm_order_delivery_rpc(uuid, jsonb, jsonb, uuid) to authenticated;

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
declare
  v_status text;
  v_data jsonb;
  v_updated_at timestamptz;
begin
  perform public.confirm_order_delivery_with_credit(p_order_id, p_items, p_updated_data, p_warehouse_id);

  select o.status::text, o.data, o.updated_at
  into v_status, v_data, v_updated_at
  from public.orders o
  where o.id = p_order_id;

  return jsonb_build_object(
    'orderId', p_order_id::text,
    'status', coalesce(v_status, 'delivered'),
    'data', coalesce(v_data, '{}'::jsonb),
    'updatedAt', coalesce(v_updated_at, now())
  );
end;
$$;

revoke all on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) to authenticated;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
