-- Enhanced diagnostic: create + test delivery steps on a real test order
-- This will help identify exactly which step causes "column data does not exist"

create or replace function public._diag_delivery_chain(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_data jsonb;
  v_step text;
  v_result jsonb := '{}'::jsonb;
  v_test_order_id uuid;
begin
  -- If no order ID provided or order not found, create a test order
  if p_order_id is null or p_order_id = '00000000-0000-0000-0000-000000000000' then
    v_test_order_id := gen_random_uuid();
    begin
      insert into public.orders(id, status, data, created_at, updated_at)
      values (v_test_order_id, 'pending', jsonb_build_object('orderSource','in_store','total',100,'subtotal',100), now(), now());
      v_result := v_result || jsonb_build_object('test_order', 'created', 'test_order_id', v_test_order_id::text);
    exception when others then
      return jsonb_build_object('create_test_order_error', SQLERRM, 'code', SQLSTATE);
    end;
    p_order_id := v_test_order_id;
  end if;

  -- Step 1: Can we read orders?
  v_step := '1_select_orders';
  begin
    select o.*
    into v_order
    from public.orders o
    where o.id = p_order_id;
    if not found then
      return jsonb_build_object('step', v_step, 'error', 'order not found');
    end if;
    v_result := v_result || jsonb_build_object('step1', 'OK', 'has_data', v_order.data is not null, 'data_keys', (select jsonb_agg(key) from jsonb_each(coalesce(v_order.data, '{}'::jsonb))));
  exception when others then
    return v_result || jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 2: Can we UPDATE orders SET data?
  v_step := '2_update_orders_data_noop';
  begin
    update public.orders
    set data = coalesce(data, '{}'::jsonb),
        updated_at = now()
    where id = p_order_id;
    v_result := v_result || jsonb_build_object('step2', 'OK');
  exception when others then
    v_result := v_result || jsonb_build_object('step2', 'FAILED', 'step2_error', SQLERRM, 'step2_code', SQLSTATE);
    -- Don't return - continue with other steps
  end;

  -- Step 3: UPDATE orders SET status = 'delivered', data = data
  v_step := '3_update_orders_status_delivered';
  begin
    update public.orders
    set status = 'delivered',
        data = coalesce(data, '{}'::jsonb),
        updated_at = now()
    where id = p_order_id;
    v_result := v_result || jsonb_build_object('step3', 'OK');
  exception when others then
    v_result := v_result || jsonb_build_object('step3', 'FAILED', 'step3_error', SQLERRM, 'step3_code', SQLSTATE);
  end;

  -- Step 4: List all triggers on orders table
  v_step := '4_list_triggers';
  begin
    select jsonb_agg(jsonb_build_object(
      'name', t.trigger_name,
      'event', t.event_manipulation,
      'timing', t.action_timing,
      'type', t.action_orientation
    ))
    into v_data
    from information_schema.triggers t
    where t.event_object_schema = 'public'
      and t.event_object_table = 'orders';
    v_result := v_result || jsonb_build_object('step4_triggers', coalesce(v_data, '[]'::jsonb));
  exception when others then
    v_result := v_result || jsonb_build_object('step4', 'FAILED', 'step4_error', SQLERRM);
  end;

  -- Step 5: Check which columns orders table has
  v_step := '5_orders_columns';
  begin
    select jsonb_agg(c.column_name order by c.ordinal_position)
    into v_data
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'orders';
    v_result := v_result || jsonb_build_object('step5_orders_columns', coalesce(v_data, '[]'::jsonb));
  exception when others then
    v_result := v_result || jsonb_build_object('step5', 'FAILED', 'step5_error', SQLERRM);
  end;

  -- Cleanup test order
  if v_test_order_id is not null then
    begin
      delete from public.orders where id = v_test_order_id;
      v_result := v_result || jsonb_build_object('cleanup', 'OK');
    exception when others then
      v_result := v_result || jsonb_build_object('cleanup', 'FAILED', 'cleanup_error', SQLERRM);
    end;
  end if;

  return v_result;
end;
$$;

grant execute on function public._diag_delivery_chain(uuid) to authenticated;
grant execute on function public._diag_delivery_chain(uuid) to anon;
grant execute on function public._diag_delivery_chain(uuid) to service_role;
select pg_sleep(0.5);
notify pgrst, 'reload schema';
