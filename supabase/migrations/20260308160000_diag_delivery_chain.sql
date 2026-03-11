-- Diagnostic: create temp function to test the delivery chain step by step
-- This will help identify EXACTLY where "column data does not exist" comes from

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
begin
  -- Step 1: Can we read orders?
  v_step := '1_select_orders';
  begin
    select o.id, o.status, o.data, o.currency, o.fx_rate, o.base_total, o.warehouse_id, o.party_id
    into v_order
    from public.orders o
    where o.id = p_order_id;
    if not found then
      return jsonb_build_object('step', v_step, 'error', 'order not found');
    end if;
    v_result := v_result || jsonb_build_object('step1', 'OK', 'has_data', v_order.data is not null);
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 2: Can we read app_settings.data?
  v_step := '2_app_settings_data';
  begin
    select s.data into v_data from public.app_settings s where s.id = 'singleton';
    v_result := v_result || jsonb_build_object('step2', 'OK', 'settings_has_data', v_data is not null);
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 3: Can we INSERT into order_events?
  v_step := '3_insert_order_events';
  begin
    -- Check if table exists and what columns it has
    if to_regclass('public.order_events') is not null then
      -- Try to check if order_events has a data column
      perform 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'order_events'
        and column_name = 'data';
      if found then
        v_result := v_result || jsonb_build_object('step3', 'order_events.data EXISTS');
      else
        v_result := v_result || jsonb_build_object('step3', 'order_events.data MISSING');
      end if;
    else
      v_result := v_result || jsonb_build_object('step3', 'order_events table not found');
    end if;
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 4: Check journal_entries for data column
  v_step := '4_journal_entries_data';
  begin
    perform 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'journal_entries'
      and column_name = 'data';
    if found then
      v_result := v_result || jsonb_build_object('step4', 'journal_entries.data EXISTS');
    else
      v_result := v_result || jsonb_build_object('step4', 'journal_entries.data MISSING');
    end if;
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 5: Check stock_management for data column
  v_step := '5_stock_management_data';
  begin
    perform 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'stock_management'
      and column_name = 'data';
    if found then
      v_result := v_result || jsonb_build_object('step5', 'stock_management.data EXISTS');
    else
      v_result := v_result || jsonb_build_object('step5', 'stock_management.data MISSING');
    end if;
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 6: Check order_item_cogs for data column
  v_step := '6_order_item_cogs_data';
  begin
    perform 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'order_item_cogs'
      and column_name = 'data';
    if found then
      v_result := v_result || jsonb_build_object('step6', 'order_item_cogs.data EXISTS');
    else
      v_result := v_result || jsonb_build_object('step6', 'order_item_cogs.data MISSING');
    end if;
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 7: Try SELECT * from orders to validate all columns are accessible
  v_step := '7_orders_star_select';
  begin
    perform o.* from public.orders o where o.id = p_order_id;
    v_result := v_result || jsonb_build_object('step7', 'OK');
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 8: Test UPDATE orders SET data = data (no change) to see if triggers fire OK
  v_step := '8_update_orders_data';
  begin
    update public.orders
    set data = coalesce(data, '{}'::jsonb),
        updated_at = updated_at -- no actual change
    where id = p_order_id;
    v_result := v_result || jsonb_build_object('step8', 'OK');
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 9: Check all triggers on orders table
  v_step := '9_list_triggers';
  begin
    select jsonb_agg(jsonb_build_object(
      'name', t.trigger_name,
      'event', t.event_manipulation,
      'timing', t.action_timing
    ))
    into v_data
    from information_schema.triggers t
    where t.event_object_schema = 'public'
      and t.event_object_table = 'orders';
    v_result := v_result || jsonb_build_object('step9_triggers', coalesce(v_data, '[]'::jsonb));
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  -- Step 10: Check all functions that reference NEW.data in their source
  v_step := '10_functions_with_new_data';
  begin
    select jsonb_agg(p.proname)
    into v_data
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc like '%NEW.data%'
    limit 50;
    v_result := v_result || jsonb_build_object('step10_funcs_with_new_data', coalesce(v_data, '[]'::jsonb));
  exception when others then
    return jsonb_build_object('step', v_step, 'error', SQLERRM, 'code', SQLSTATE);
  end;

  return v_result;
end;
$$;

grant execute on function public._diag_delivery_chain(uuid) to authenticated;
grant execute on function public._diag_delivery_chain(uuid) to service_role;
notify pgrst, 'reload schema';
