-- Diagnostic RPC for item efa91e13-9cb2-4fb1-b3f0-4f711c22e59a
-- Returns comprehensive diagnostic data as JSON
-- Will be removed after diagnosis

create or replace function public.diag_item_batches(p_item_id text default 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb := '{}'::jsonb;
  v_batches jsonb;
  v_receipts jsonb;
  v_movements jsonb;
  v_returns jsonb;
  v_sales jsonb;
  v_balances jsonb;
  v_anomalous jsonb;
  v_item jsonb;
  v_pos jsonb;
  v_uom jsonb;
begin
  -- Item info + stock
  select jsonb_build_object(
    'id', mi.id, 'name', mi.name, 'base_unit', mi.base_unit, 'unit_type', mi.unit_type,
    'category', mi.category,
    'stock_available', sm.available_quantity, 'stock_reserved', sm.reserved_quantity,
    'avg_cost', sm.avg_cost, 'stock_unit', sm.unit
  ) into v_item
  from public.menu_items mi
  left join public.stock_management sm on sm.item_id::text = mi.id::text
  where mi.id::text = p_item_id;

  -- Purchase orders
  select coalesce(jsonb_agg(jsonb_build_object(
    'po_id', po.id, 'status', po.status, 'currency', po.currency, 'fx_rate', po.fx_rate,
    'total_amount', po.total_amount, 'paid_amount', po.paid_amount,
    'purchase_date', po.purchase_date::text,
    'ordered_qty', pi.quantity, 'received_qty', pi.received_quantity,
    'unit_cost', pi.unit_cost, 'unit_cost_base', pi.unit_cost_base,
    'unit_cost_foreign', pi.unit_cost_foreign, 'uom_id', pi.uom_id, 'qty_base', pi.qty_base
  ) order by po.created_at), '[]'::jsonb) into v_pos
  from public.purchase_items pi
  join public.purchase_orders po on po.id = pi.purchase_order_id
  where pi.item_id::text = p_item_id;

  -- UOM
  select coalesce(jsonb_agg(jsonb_build_object(
    'base_uom_id', iu.base_uom_id, 'uom_id', iu.uom_id,
    'conversion_factor', iu.conversion_factor
  )), '[]'::jsonb) into v_uom
  from public.item_uom iu where iu.item_id::text = p_item_id;

  -- All batches
  select coalesce(jsonb_agg(jsonb_build_object(
    'batch_id', b.id, 'receipt_id', b.receipt_id,
    'qty_received', b.quantity_received, 'qty_consumed', b.quantity_consumed,
    'qty_transferred', coalesce(b.quantity_transferred, 0),
    'remaining', (b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0)),
    'unit_cost', b.unit_cost, 'foreign_unit_cost', b.foreign_unit_cost,
    'foreign_currency', b.foreign_currency, 'fx_rate', b.fx_rate_at_receipt,
    'qc_status', b.qc_status, 'status', b.status,
    'created_at', b.created_at::text
  ) order by b.created_at), '[]'::jsonb) into v_batches
  from public.batches b where b.item_id::text = p_item_id;

  -- Receipts
  select coalesce(jsonb_agg(jsonb_build_object(
    'receipt_id', pr.id, 'po_id', pr.purchase_order_id,
    'quantity', pri.quantity, 'unit_cost', pri.unit_cost, 'total_cost', pri.total_cost,
    'transport_cost', pri.transport_cost, 'supply_tax_cost', pri.supply_tax_cost,
    'uom_id', pri.uom_id,
    'received_at', pr.received_at::text,
    'idempotency_key', pr.idempotency_key
  ) order by pr.received_at), '[]'::jsonb) into v_receipts
  from public.purchase_receipt_items pri
  join public.purchase_receipts pr on pr.id = pri.receipt_id
  where pri.item_id::text = p_item_id;

  -- Movement summary
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', x.movement_type, 'count', x.cnt, 'total_qty', x.total_qty, 'total_cost', x.total_cost
  )), '[]'::jsonb) into v_movements
  from (
    select im.movement_type, count(*) as cnt, sum(im.quantity) as total_qty, sum(im.total_cost) as total_cost
    from public.inventory_movements im
    where im.item_id::text = p_item_id
    group by im.movement_type
  ) x;

  -- Anomalous batches (cost > 100)
  select coalesce(jsonb_agg(jsonb_build_object(
    'batch_id', b.id, 'unit_cost', b.unit_cost, 'foreign_unit_cost', b.foreign_unit_cost,
    'fx_rate', b.fx_rate_at_receipt, 'foreign_currency', b.foreign_currency,
    'qty_received', b.quantity_received, 'receipt_id', b.receipt_id,
    'created_at', b.created_at::text,
    'receipt_idempotency', pr.idempotency_key,
    'receipt_date', pr.received_at::text,
    'receipt_item_cost', pri.unit_cost,
    'receipt_item_qty', pri.quantity,
    'receipt_item_total', pri.total_cost,
    'receipt_transport', pri.transport_cost,
    'receipt_tax', pri.supply_tax_cost,
    'po_currency', po.currency, 'po_fx', po.fx_rate,
    'pi_unit_cost', pi.unit_cost, 'pi_cost_base', pi.unit_cost_base,
    'pi_cost_foreign', pi.unit_cost_foreign
  )), '[]'::jsonb) into v_anomalous
  from public.batches b
  join public.purchase_receipts pr on pr.id = b.receipt_id
  join public.purchase_receipt_items pri on pri.receipt_id = pr.id and pri.item_id::text = b.item_id::text
  join public.purchase_orders po on po.id = pr.purchase_order_id
  left join public.purchase_items pi on pi.purchase_order_id = po.id and pi.item_id::text = b.item_id::text
  where b.item_id::text = p_item_id
    and b.unit_cost > 100;

  -- Batch balances summary
  select coalesce(jsonb_agg(jsonb_build_object(
    'batch_id', bb.batch_id, 'quantity', bb.quantity
  )), '[]'::jsonb) into v_balances
  from public.batch_balances bb where bb.item_id::text = p_item_id and bb.quantity > 0;

  -- Returns
  select coalesce(jsonb_agg(jsonb_build_object(
    'return_id', pret.id, 'po_id', pret.purchase_order_id,
    'quantity', preti.quantity, 'unit_cost', preti.unit_cost,
    'returned_at', pret.returned_at::text
  )), '[]'::jsonb) into v_returns
  from public.purchase_return_items preti
  join public.purchase_returns pret on pret.id = preti.return_id
  where preti.item_id::text = p_item_id;

  -- Sales summary
  select jsonb_build_object(
    'total_orders', count(distinct oi.order_id),
    'total_qty_sold', coalesce(sum(oi.quantity), 0)
  ) into v_sales
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  where oi.item_id::text = p_item_id and o.status not in ('cancelled');

  v_result := jsonb_build_object(
    'item', v_item,
    'purchase_orders', v_pos,
    'uom', v_uom,
    'batch_count', (select count(*) from public.batches b where b.item_id::text = p_item_id),
    'batches', v_batches,
    'receipts', v_receipts,
    'receipt_count', (select count(*) from public.purchase_receipt_items pri where pri.item_id::text = p_item_id),
    'movement_summary', v_movements,
    'anomalous_batches', v_anomalous,
    'batch_balances_nonzero', v_balances,
    'returns', v_returns,
    'sales', v_sales
  );

  return v_result;
end;
$$;

grant execute on function public.diag_item_batches(text) to authenticated;
notify pgrst, 'reload schema';
