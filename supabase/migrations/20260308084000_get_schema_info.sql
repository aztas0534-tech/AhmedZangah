create or replace function public.get_schema_info()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_im_cols jsonb;
  v_cogs_cols jsonb;
  v_order_cols jsonb;
  v_stock_cols jsonb;
  v_batches_cols jsonb;
  v_triggers_im jsonb;
  v_triggers_orders jsonb;
  v_triggers_batches jsonb;
  v_triggers_stock jsonb;
  v_funcs jsonb;
begin
  select jsonb_agg(column_name) into v_im_cols from information_schema.columns where table_schema = 'public' and table_name = 'inventory_movements';
  select jsonb_agg(column_name) into v_cogs_cols from information_schema.columns where table_schema = 'public' and table_name = 'order_item_cogs';
  select jsonb_agg(column_name) into v_order_cols from information_schema.columns where table_schema = 'public' and table_name = 'orders';
  select jsonb_agg(column_name) into v_stock_cols from information_schema.columns where table_schema = 'public' and table_name = 'stock_management';
  select jsonb_agg(column_name) into v_batches_cols from information_schema.columns where table_schema = 'public' and table_name = 'batches';

  select jsonb_agg(format('%s: %s', tgname, pg_get_triggerdef(t.oid))) into v_triggers_im
  from pg_trigger t join pg_class c on t.tgrelid = c.oid
  where c.relname = 'inventory_movements' and c.relnamespace = 'public'::regnamespace;

  select jsonb_agg(format('%s: %s', tgname, pg_get_triggerdef(t.oid))) into v_triggers_orders
  from pg_trigger t join pg_class c on t.tgrelid = c.oid
  where c.relname = 'orders' and c.relnamespace = 'public'::regnamespace;

  select jsonb_agg(format('%s: %s', tgname, pg_get_triggerdef(t.oid))) into v_triggers_batches
  from pg_trigger t join pg_class c on t.tgrelid = c.oid
  where c.relname = 'batches' and c.relnamespace = 'public'::regnamespace;

  select jsonb_agg(format('%s: %s', tgname, pg_get_triggerdef(t.oid))) into v_triggers_stock
  from pg_trigger t join pg_class c on t.tgrelid = c.oid
  where c.relname = 'stock_management' and c.relnamespace = 'public'::regnamespace;

  select jsonb_agg(jsonb_build_object('name', p.proname, 'src', p.prosrc)) into v_funcs
  from pg_proc p
  join pg_trigger t on t.tgfoid = p.oid
  join pg_class c on t.tgrelid = c.oid
  where c.relname in ('orders', 'inventory_movements', 'batches', 'stock_management')
    and c.relnamespace = 'public'::regnamespace
    and t.tgname not like 'RI_%';

  return jsonb_build_object(
    'im_cols', v_im_cols,
    'cogs_cols', v_cogs_cols,
    'order_cols', v_order_cols,
    'stock_cols', v_stock_cols,
    'batches_cols', v_batches_cols,
    'triggers_im', v_triggers_im,
    'triggers_orders', v_triggers_orders,
    'triggers_batches', v_triggers_batches,
    'triggers_stock', v_triggers_stock,
    'funcs', v_funcs
  );
end;
$$;

revoke all on function public.get_schema_info() from public;
grant execute on function public.get_schema_info() to anon, authenticated;

notify pgrst, 'reload schema';
