set app.allow_ledger_ddl = '1';

create or replace function public.normalize_batch_unit_cost_by_trx_qty(
  p_batch_id uuid,
  p_reason text,
  p_post_journal boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
  v_trx_qty numeric;
  v_factor numeric;
  v_old numeric;
  v_new numeric;
  v_price numeric;
  v_item_id text;
begin
  if not public.has_admin_permission('accounting.manage') then
    raise exception 'not allowed';
  end if;
  if p_batch_id is null then
    raise exception 'p_batch_id is required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'reason is required';
  end if;

  select
    b.id,
    b.item_id::text as item_id,
    b.warehouse_id,
    coalesce(b.unit_cost, 0) as unit_cost,
    coalesce(b.quantity_received, 0) as quantity_received,
    b.data
  into v_b
  from public.batches b
  where b.id = p_batch_id
  for update;
  if not found then
    raise exception 'batch not found';
  end if;

  v_item_id := v_b.item_id;
  begin
    v_trx_qty := nullif(btrim(coalesce(v_b.data->>'trxQty', '')), '')::numeric;
  exception when others then
    v_trx_qty := null;
  end;

  if v_trx_qty is null or v_trx_qty <= 0 then
    raise exception 'trxQty missing on batch';
  end if;
  if coalesce(v_b.quantity_received, 0) <= 0 then
    raise exception 'quantity_received missing on batch';
  end if;

  v_factor := coalesce(v_b.quantity_received, 0) / nullif(v_trx_qty, 0);
  if v_factor is null or v_factor <= 1.0001 then
    raise exception 'no uom factor inferred';
  end if;

  select coalesce(mi.price, 0) into v_price
  from public.menu_items mi
  where mi.id::text = v_item_id
  limit 1;

  v_old := coalesce(v_b.unit_cost, 0);
  v_new := round(v_old / v_factor, 6);
  if v_new <= 0 then
    raise exception 'computed unit cost invalid';
  end if;

  if v_old < 50 then
    raise exception 'unit_cost not high enough to normalize safely';
  end if;
  if coalesce(v_price, 0) > 0 and v_old <= (v_price * 5) then
    raise exception 'unit_cost not outlier vs selling price';
  end if;

  perform public.revalue_batch_unit_cost(p_batch_id, v_new, concat('normalize_by_trxQty: ', p_reason), coalesce(p_post_journal, true));
  return jsonb_build_object(
    'batchId', p_batch_id::text,
    'itemId', v_item_id,
    'oldUnitCost', v_old,
    'newUnitCost', v_new,
    'factor', v_factor,
    'trxQty', v_trx_qty,
    'qtyBase', coalesce(v_b.quantity_received, 0)
  );
end;
$$;

revoke all on function public.normalize_batch_unit_cost_by_trx_qty(uuid, text, boolean) from public;
grant execute on function public.normalize_batch_unit_cost_by_trx_qty(uuid, text, boolean) to authenticated;

notify pgrst, 'reload schema';
