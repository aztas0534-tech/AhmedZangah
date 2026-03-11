-- Diagnostic v3: dump actual function source from pg_proc to find
-- which function references "data" column on a wrong table

create or replace function public._diag_delivery_chain(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb := '{}'::jsonb;
  v_funcs jsonb;
  v_src text;
begin
  -- 1. List ALL overloads of confirm_order_delivery with their source snippets
  select jsonb_agg(jsonb_build_object(
    'oid', p.oid::text,
    'name', p.proname,
    'args', pg_catalog.pg_get_function_arguments(p.oid),
    'src_first_200', left(p.prosrc, 200),
    'src_last_200', right(p.prosrc, 200),
    'src_length', length(p.prosrc),
    'has_dot_data', (p.prosrc like '%.data%')::text,
    'has_NEW_data', (p.prosrc like '%NEW.data%')::text,
    'has_select_data', (p.prosrc like '%select%data%from%')::text
  ))
  into v_funcs
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('confirm_order_delivery', 'confirm_order_delivery_rpc',
                      'confirm_order_delivery_with_credit', 'confirm_order_delivery_with_credit_rpc');
  v_result := v_result || jsonb_build_object('confirm_delivery_overloads', coalesce(v_funcs, '[]'::jsonb));

  -- 2. List ALL overloads of deduct_stock_on_delivery_v2
  select jsonb_agg(jsonb_build_object(
    'oid', p.oid::text,
    'name', p.proname,
    'args', pg_catalog.pg_get_function_arguments(p.oid),
    'src_first_200', left(p.prosrc, 200),
    'has_dot_data', (p.prosrc like '%.data%')::text,
    'src_length', length(p.prosrc)
  ))
  into v_funcs
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'deduct_stock_on_delivery_v2';
  v_result := v_result || jsonb_build_object('deduct_stock_overloads', coalesce(v_funcs, '[]'::jsonb));

  -- 3. Find ALL trigger functions that reference NEW.data or OLD.data 
  select jsonb_agg(jsonb_build_object(
    'name', p.proname,
    'has_NEW_data', (p.prosrc like '%NEW.data%')::text,
    'has_OLD_data', (p.prosrc like '%OLD.data%')::text,
    'src_snippet_around_data', substring(p.prosrc from position('data' in p.prosrc) - 30 for 80)
  ))
  into v_funcs
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and (p.prosrc like '%NEW.data%' or p.prosrc like '%OLD.data%')
    and p.proname like 'trg_%';
  v_result := v_result || jsonb_build_object('trigger_funcs_with_data', coalesce(v_funcs, '[]'::jsonb));

  -- 4. Check post_inventory_movement - does it reference .data?
  select jsonb_agg(jsonb_build_object(
    'name', p.proname,
    'args', pg_catalog.pg_get_function_arguments(p.oid),
    'has_dot_data', (p.prosrc like '%.data%')::text,
    'src_length', length(p.prosrc),
    'src_first_300', left(p.prosrc, 300)
  ))
  into v_funcs
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('post_inventory_movement', 'post_order_delivery', 'trg_post_order_delivery',
                      '_is_cod_delivery_order', 'issue_invoice_number_if_needed',
                      'trg_orders_require_sale_out_on_delivered',
                      'trg_issue_invoice_on_delivery', 'trg_set_order_fx',
                      'trg_enforce_discount_approval', 'trg_orders_forbid_posted_updates',
                      'trg_sync_order_line_items', 'trg_orders_sync_terms',
                      'trg_validate_invoice_snapshot');
  v_result := v_result || jsonb_build_object('delivery_chain_funcs', coalesce(v_funcs, '[]'::jsonb));

  -- 5. Check if there's a VIEW on orders that might fail
  select jsonb_agg(jsonb_build_object(
    'view_name', v.table_name,
    'definition_snippet', left(v.view_definition, 300)
  ))
  into v_funcs
  from information_schema.views v
  where v.table_schema = 'public'
    and v.view_definition like '%orders%'
    and v.view_definition like '%data%';
  v_result := v_result || jsonb_build_object('views_with_orders_data', coalesce(v_funcs, '[]'::jsonb));

  return v_result;
end;
$$;

grant execute on function public._diag_delivery_chain(uuid) to authenticated;
grant execute on function public._diag_delivery_chain(uuid) to anon;
grant execute on function public._diag_delivery_chain(uuid) to service_role;
select pg_sleep(0.5);
notify pgrst, 'reload schema';
