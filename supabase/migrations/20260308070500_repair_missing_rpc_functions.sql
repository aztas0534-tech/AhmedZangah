-- ============================================================================
-- Emergency repair: recreate missing RPC function overloads
-- Fixes:
--   1. get_item_price_with_discount(text, uuid, numeric) - text overload
--   2. deduct_stock_on_delivery_v2(jsonb, uuid, uuid) - alternate arg order
--   3. confirm_order_delivery_with_credit_rpc - alias for confirm_order_delivery
--   4. confirm_order_delivery_rpc - alias for confirm_order_delivery
--   5. get_fefo_pricing grant to authenticated
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- 1. Ensure _uuid_or_null helper exists
create or replace function public._uuid_or_null(p_value text)
returns uuid
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  return p_value::uuid;
exception when others then
  return null;
end;
$$;

-- 2. Recreate text overload of get_item_price_with_discount
create or replace function public.get_item_price_with_discount(
  p_item_id text,
  p_customer_id uuid default null,
  p_quantity numeric default 1
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_uuid uuid;
begin
  v_item_uuid := public._uuid_or_null(p_item_id);
  if v_item_uuid is null then
    raise exception 'Invalid item id (expected UUID): %', coalesce(p_item_id, '');
  end if;
  return public.get_item_price_with_discount(v_item_uuid, p_customer_id, p_quantity);
end;
$$;

revoke all on function public.get_item_price_with_discount(text, uuid, numeric) from public;
grant execute on function public.get_item_price_with_discount(text, uuid, numeric) to anon, authenticated;

-- 3. Ensure alternate arg order overload of deduct_stock_on_delivery_v2 exists
-- The confirm_order_delivery function tries (v_items_all, p_order_id, p_warehouse_id)
-- but the main function is (p_order_id, p_items, p_warehouse_id)
do $$
begin
  -- Check if the (jsonb, uuid, uuid) overload exists
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'deduct_stock_on_delivery_v2'
      and p.pronargs = 3
      and p.proargtypes[0] = 'jsonb'::regtype::oid
  ) then
    execute $fn$
    create or replace function public.deduct_stock_on_delivery_v2(
      p_items jsonb,
      p_order_id uuid,
      p_warehouse_id uuid
    )
    returns void
    language plpgsql
    security definer
    set search_path = public
    as $inner$
    begin
      perform public.deduct_stock_on_delivery_v2(p_order_id, p_items, p_warehouse_id);
    end;
    $inner$;
    revoke all on function public.deduct_stock_on_delivery_v2(jsonb, uuid, uuid) from public;
    grant execute on function public.deduct_stock_on_delivery_v2(jsonb, uuid, uuid) to authenticated;
    $fn$;
  end if;
end $$;

-- 4. Ensure confirm_order_delivery_with_credit exists as alias
create or replace function public.confirm_order_delivery_with_credit(
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
  if auth.role() <> 'service_role' then
    if not public.is_staff() then
      raise exception 'not allowed';
    end if;
  end if;
  return public.confirm_order_delivery(p_order_id, p_items, p_updated_data, p_warehouse_id);
end;
$$;

revoke all on function public.confirm_order_delivery_with_credit(uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.confirm_order_delivery_with_credit(uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.confirm_order_delivery_with_credit(uuid, jsonb, jsonb, uuid) to authenticated;

-- 5. Ensure _rpc aliases exist
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
  return public.confirm_order_delivery(p_order_id, p_items, p_updated_data, p_warehouse_id);
end;
$$;

revoke all on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.confirm_order_delivery_with_credit_rpc(uuid, jsonb, jsonb, uuid) to authenticated;

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

-- 6. Ensure get_fefo_pricing is accessible (all overloads)
do $$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid, pg_catalog.pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_fefo_pricing'
  loop
    execute format('grant execute on function public.get_fefo_pricing(%s) to authenticated', v_fn.args);
  end loop;
end $$;

-- 7. Ensure wrapper overloads for jsonb payload exist
create or replace function public.confirm_order_delivery_with_credit(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_updated_data jsonb;
  v_order_id_text text;
  v_warehouse_id_text text;
  v_order_id uuid;
  v_warehouse_id uuid;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'p_payload must be a json object';
  end if;

  v_items := coalesce(p_payload->'p_items', p_payload->'items', '[]'::jsonb);
  v_updated_data := coalesce(p_payload->'p_updated_data', p_payload->'updated_data', '{}'::jsonb);

  v_order_id_text := nullif(coalesce(p_payload->>'p_order_id', p_payload->>'order_id', p_payload->>'orderId'), '');
  if v_order_id_text is null then
    raise exception 'p_order_id is required';
  end if;
  v_order_id := v_order_id_text::uuid;

  v_warehouse_id_text := nullif(coalesce(p_payload->>'p_warehouse_id', p_payload->>'warehouse_id', p_payload->>'warehouseId'), '');
  if v_warehouse_id_text is null then
    raise exception 'p_warehouse_id is required';
  end if;
  v_warehouse_id := v_warehouse_id_text::uuid;

  return public.confirm_order_delivery(v_order_id, v_items, v_updated_data, v_warehouse_id);
end;
$$;

revoke all on function public.confirm_order_delivery_with_credit(jsonb) from public;
revoke execute on function public.confirm_order_delivery_with_credit(jsonb) from anon;
grant execute on function public.confirm_order_delivery_with_credit(jsonb) to authenticated;

-- Force PostgREST reload
select pg_sleep(1);
notify pgrst, 'reload schema';
notify pgrst, 'reload config';
