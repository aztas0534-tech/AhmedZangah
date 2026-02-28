drop function if exists public.diag_get_anomaly_details;
create or replace function public.diag_get_anomaly_details()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_id uuid;
  v_res jsonb;
  v_batches jsonb;
  v_movements jsonb;
  v_balances jsonb;
  v_returns jsonb;
begin
  select id into v_item_id
  from public.menu_items
  where name->>'ar' like '%ماء طيبة صغير%'
  limit 1;

  if v_item_id is null then
    return '{"error": "Item not found"}'::jsonb;
  end if;

  select jsonb_agg(b) into v_batches
  from (select id, quantity_received, quantity_consumed, status, qc_status, unit_cost from public.batches where item_id = v_item_id::text) b;

  select jsonb_agg(m) into v_movements
  from (select id, batch_id, movement_type, quantity, unit_cost, reference_table, occurred_at from public.inventory_movements where item_id = v_item_id::text order by occurred_at asc) m;

  select jsonb_agg(bb) into v_balances
  from (select batch_id, quantity from public.batch_balances where item_id = v_item_id::text) bb;

  select jsonb_agg(r) into v_returns
  from (select pri.id, pri.return_id, pri.quantity, pri.unit_cost from public.purchase_return_items pri where pri.item_id = v_item_id::text) r;

  v_res := jsonb_build_object(
    'item_id', v_item_id,
    'batches', coalesce(v_batches, '[]'::jsonb),
    'movements', coalesce(v_movements, '[]'::jsonb),
    'batch_balances', coalesce(v_balances, '[]'::jsonb),
    'returns', coalesce(v_returns, '[]'::jsonb)
  );

  return v_res;
end;
$$;
revoke all on function public.diag_get_anomaly_details() from public;
grant execute on function public.diag_get_anomaly_details() to anon, authenticated;
