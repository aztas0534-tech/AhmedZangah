import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

await client.connect();
try {
  const actor = (await client.query(`
    select auth_user_id
    from public.admin_users
    where is_active = true
    order by (case when role='owner' then 1 else 0 end) desc, created_at asc nulls last
    limit 1
  `)).rows[0];
  if (!actor?.auth_user_id) throw new Error('No active admin user');

  await client.query(
    `select
      set_config('request.jwt.claim.sub',$1::text,false),
      set_config('request.jwt.claim.role','authenticated',false),
      set_config('request.jwt.claims',json_build_object('sub',$1::text,'role','authenticated')::text,false)`,
    [actor.auth_user_id]
  );

  const overview = (await client.query(`
    select
      (select count(*) from public.menu_items) as items_count,
      (select count(*) from public.stock_management) as stock_rows_count,
      (select count(*) from public.batches where coalesce(status,'active')='active') as active_batches_count,
      (select count(*) from public.inventory_movements) as inventory_movements_count,
      (select count(*) from public.purchase_orders) as purchase_orders_count,
      (select count(*) from public.purchase_returns) as purchase_returns_count
  `)).rows[0];

  const stockVsBatches = (await client.query(`
    with b_all as (
      select
        b.item_id::text as item_id,
        b.warehouse_id,
        sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) as rem_all
      from public.batches b
      where coalesce(b.status,'active')='active'
      group by b.item_id::text, b.warehouse_id
    ),
    b_rel as (
      select
        b.item_id::text as item_id,
        b.warehouse_id,
        sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) as rem_released
      from public.batches b
      where coalesce(b.status,'active')='active'
        and coalesce(b.qc_status,'released')='released'
      group by b.item_id::text, b.warehouse_id
    ),
    s as (
      select
        sm.item_id::text as item_id,
        sm.warehouse_id,
        coalesce(sm.available_quantity,0) as avail,
        coalesce(sm.qc_hold_quantity,0) as qc_hold,
        coalesce(sm.reserved_quantity,0) as reserved
      from public.stock_management sm
    )
    select
      coalesce(s.item_id,b_all.item_id,b_rel.item_id) as item_id,
      mi.data->'name'->>'ar' as item_name,
      coalesce(s.warehouse_id,b_all.warehouse_id,b_rel.warehouse_id)::text as warehouse_id,
      w.name as warehouse_name,
      coalesce(s.avail,0) as available_qty,
      coalesce(s.qc_hold,0) as qc_hold_qty,
      coalesce(s.reserved,0) as reserved_qty,
      coalesce(b_all.rem_all,0) as batches_remaining_all,
      coalesce(b_rel.rem_released,0) as batches_remaining_released,
      coalesce(s.avail,0)-coalesce(b_all.rem_all,0) as delta_vs_all,
      coalesce(s.avail,0)-coalesce(b_rel.rem_released,0) as delta_vs_released
    from s
    full join b_all using(item_id, warehouse_id)
    full join b_rel using(item_id, warehouse_id)
    left join public.menu_items mi on mi.id::text = coalesce(s.item_id,b_all.item_id,b_rel.item_id)
    left join public.warehouses w on w.id = coalesce(s.warehouse_id,b_all.warehouse_id,b_rel.warehouse_id)
    where abs(coalesce(s.avail,0)-coalesce(b_rel.rem_released,0)) > 0.0001
       or abs(coalesce(s.avail,0)-coalesce(b_all.rem_all,0)) > 0.0001
    order by abs(coalesce(s.avail,0)-coalesce(b_rel.rem_released,0)) desc, abs(coalesce(s.avail,0)-coalesce(b_all.rem_all,0)) desc
    limit 300
  `)).rows;

  const batchMovementConsistency = (await client.query(`
    with out_mv as (
      select
        im.batch_id::text as batch_id,
        sum(case when im.movement_type='sale_out' then im.quantity else 0 end) as sale_out_qty,
        sum(case when im.movement_type='return_out' then im.quantity else 0 end) as return_out_qty,
        sum(case when im.movement_type='wastage_out' then im.quantity else 0 end) as wastage_out_qty,
        sum(case when im.movement_type='adjust_out' then im.quantity else 0 end) as adjust_out_qty,
        sum(case when im.movement_type='transfer_out' then im.quantity else 0 end) as transfer_out_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      mi.data->'name'->>'ar' as item_name,
      b.warehouse_id::text as warehouse_id,
      w.name as warehouse_name,
      coalesce(b.quantity_received,0) as quantity_received,
      coalesce(b.quantity_consumed,0) as quantity_consumed,
      coalesce(b.quantity_transferred,0) as quantity_transferred,
      coalesce(o.sale_out_qty,0) as sale_out_qty,
      coalesce(o.return_out_qty,0) as return_out_qty,
      coalesce(o.wastage_out_qty,0) as wastage_out_qty,
      coalesce(o.adjust_out_qty,0) as adjust_out_qty,
      coalesce(o.transfer_out_qty,0) as transfer_out_qty,
      coalesce(o.sale_out_qty,0)+coalesce(o.return_out_qty,0)+coalesce(o.wastage_out_qty,0)+coalesce(o.adjust_out_qty,0)+coalesce(o.transfer_out_qty,0) as outbound_total,
      coalesce(b.quantity_consumed,0)-(
        coalesce(o.sale_out_qty,0)+coalesce(o.return_out_qty,0)+coalesce(o.wastage_out_qty,0)+coalesce(o.adjust_out_qty,0)+coalesce(o.transfer_out_qty,0)
      ) as consumed_delta
    from public.batches b
    left join out_mv o on o.batch_id = b.id::text
    left join public.menu_items mi on mi.id::text = b.item_id::text
    left join public.warehouses w on w.id = b.warehouse_id
    where abs(
      coalesce(b.quantity_consumed,0)-(
        coalesce(o.sale_out_qty,0)+coalesce(o.return_out_qty,0)+coalesce(o.wastage_out_qty,0)+coalesce(o.adjust_out_qty,0)+coalesce(o.transfer_out_qty,0)
      )
    ) > 0.0001
    order by abs(
      coalesce(b.quantity_consumed,0)-(
        coalesce(o.sale_out_qty,0)+coalesce(o.return_out_qty,0)+coalesce(o.wastage_out_qty,0)+coalesce(o.adjust_out_qty,0)+coalesce(o.transfer_out_qty,0)
      )
    ) desc
    limit 300
  `)).rows;

  const unbatchedOutMovements = (await client.query(`
    select
      im.item_id::text as item_id,
      mi.data->'name'->>'ar' as item_name,
      im.warehouse_id::text as warehouse_id,
      w.name as warehouse_name,
      im.movement_type,
      count(*) as rows_count,
      sum(coalesce(im.quantity,0)) as total_qty
    from public.inventory_movements im
    left join public.menu_items mi on mi.id::text = im.item_id::text
    left join public.warehouses w on w.id = im.warehouse_id
    where im.batch_id is null
      and im.movement_type in ('sale_out','return_out','wastage_out','adjust_out')
    group by im.item_id::text, mi.data->'name'->>'ar', im.warehouse_id::text, w.name, im.movement_type
    order by sum(coalesce(im.quantity,0)) desc
    limit 300
  `)).rows;

  const fxCostAnomalies = (await client.query(`
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      mi.data->'name'->>'ar' as item_name,
      b.warehouse_id::text as warehouse_id,
      w.name as warehouse_name,
      b.foreign_currency,
      b.fx_rate_at_receipt,
      b.foreign_unit_cost,
      b.unit_cost,
      round(coalesce(b.foreign_unit_cost,0) * coalesce(b.fx_rate_at_receipt,0), 6) as expected_unit_cost,
      round(coalesce(b.unit_cost,0) - round(coalesce(b.foreign_unit_cost,0) * coalesce(b.fx_rate_at_receipt,0), 6), 6) as unit_cost_delta
    from public.batches b
    left join public.menu_items mi on mi.id::text = b.item_id::text
    left join public.warehouses w on w.id = b.warehouse_id
    where coalesce(b.status,'active')='active'
      and nullif(trim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(trim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency())
      and coalesce(b.fx_rate_at_receipt,0) > 0
      and coalesce(b.foreign_unit_cost,0) > 0
      and abs(coalesce(b.unit_cost,0) - round(coalesce(b.foreign_unit_cost,0) * coalesce(b.fx_rate_at_receipt,0), 6)) > 0.01
    order by abs(coalesce(b.unit_cost,0) - round(coalesce(b.foreign_unit_cost,0) * coalesce(b.fx_rate_at_receipt,0), 6)) desc
    limit 300
  `)).rows;

  const uomFactorAnomalies = (await client.query(`
    select
      pi.purchase_order_id::text as purchase_order_id,
      po.po_number,
      pi.item_id::text as item_id,
      mi.data->'name'->>'ar' as item_name,
      sum(coalesce(pi.quantity,0)) as qty_uom_sum,
      sum(coalesce(pi.qty_base,0)) as qty_base_sum,
      case when sum(coalesce(pi.quantity,0)) > 0 then sum(coalesce(pi.qty_base,0))/sum(coalesce(pi.quantity,0)) else 0 end as uom_factor,
      min(coalesce(pi.qty_base,0)) as min_qty_base_line,
      max(coalesce(pi.qty_base,0)) as max_qty_base_line
    from public.purchase_items pi
    left join public.purchase_orders po on po.id = pi.purchase_order_id
    left join public.menu_items mi on mi.id::text = pi.item_id::text
    group by pi.purchase_order_id::text, po.po_number, pi.item_id::text, mi.data->'name'->>'ar'
    having sum(coalesce(pi.quantity,0)) > 0
       and (
         sum(coalesce(pi.qty_base,0)) <= 0
         or sum(coalesce(pi.qty_base,0))/sum(coalesce(pi.quantity,0)) <= 0
         or sum(coalesce(pi.qty_base,0))/sum(coalesce(pi.quantity,0)) > 1000
       )
    order by po.po_number desc nulls last
    limit 300
  `)).rows;

  const itemFlowSummary = (await client.query(`
    with mv as (
      select
        im.item_id::text as item_id,
        im.warehouse_id,
        sum(case when im.movement_type='purchase_in' then im.quantity else 0 end) as purchase_in_qty,
        sum(case when im.movement_type='return_out' then im.quantity else 0 end) as return_out_qty,
        sum(case when im.movement_type='sale_out' then im.quantity else 0 end) as sale_out_qty,
        sum(case when im.movement_type='wastage_out' then im.quantity else 0 end) as wastage_out_qty,
        sum(case when im.movement_type='adjust_out' then im.quantity else 0 end) as adjust_out_qty,
        sum(case when im.movement_type='adjust_in' then im.quantity else 0 end) as adjust_in_qty
      from public.inventory_movements im
      group by im.item_id::text, im.warehouse_id
    )
    select
      mv.item_id,
      mi.data->'name'->>'ar' as item_name,
      mv.warehouse_id::text as warehouse_id,
      w.name as warehouse_name,
      coalesce(mv.purchase_in_qty,0) as purchase_in_qty,
      coalesce(mv.return_out_qty,0) as return_out_qty,
      coalesce(mv.sale_out_qty,0) as sale_out_qty,
      coalesce(mv.wastage_out_qty,0) as wastage_out_qty,
      coalesce(mv.adjust_out_qty,0) as adjust_out_qty,
      coalesce(mv.adjust_in_qty,0) as adjust_in_qty,
      coalesce(sm.available_quantity,0) as available_qty,
      coalesce(sm.qc_hold_quantity,0) as qc_hold_qty,
      coalesce(sm.reserved_quantity,0) as reserved_qty
    from mv
    left join public.stock_management sm on sm.item_id::text = mv.item_id and sm.warehouse_id = mv.warehouse_id
    left join public.menu_items mi on mi.id::text = mv.item_id
    left join public.warehouses w on w.id = mv.warehouse_id
    where coalesce(mv.purchase_in_qty,0) > 0
    order by coalesce(mv.purchase_in_qty,0) desc
    limit 500
  `)).rows;

  const returnedBatches = (await client.query(`
    with m as (
      select
        im.item_id::text as item_id,
        im.batch_id::text as batch_id,
        im.warehouse_id,
        sum(case when im.movement_type='purchase_in' then im.quantity else 0 end) as received_qty,
        sum(case when im.movement_type='return_out' then im.quantity else 0 end) as returned_qty,
        sum(case when im.movement_type='sale_out' then im.quantity else 0 end) as sold_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.item_id::text, im.batch_id::text, im.warehouse_id
    )
    select
      m.item_id,
      mi.data->'name'->>'ar' as item_name,
      m.batch_id,
      m.warehouse_id::text as warehouse_id,
      w.name as warehouse_name,
      m.received_qty,
      m.returned_qty,
      m.sold_qty,
      coalesce(b.quantity_received,0) as batch_received,
      coalesce(b.quantity_consumed,0) as batch_consumed,
      greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) as batch_remaining
    from m
    left join public.batches b on b.id::text = m.batch_id
    left join public.menu_items mi on mi.id::text = m.item_id
    left join public.warehouses w on w.id = m.warehouse_id
    where coalesce(m.returned_qty,0) > 0
    order by m.returned_qty desc
    limit 500
  `)).rows;

  const report = {
    generated_at: new Date().toISOString(),
    environment: 'production',
    overview,
    diagnostics: {
      stock_vs_batches_mismatch_count: stockVsBatches.length,
      batch_movement_consistency_count: batchMovementConsistency.length,
      unbatched_out_movements_count: unbatchedOutMovements.length,
      fx_cost_anomalies_count: fxCostAnomalies.length,
      uom_factor_anomalies_count: uomFactorAnomalies.length,
      returned_batches_count: returnedBatches.length,
    },
    stock_vs_batches_mismatch_top: stockVsBatches,
    batch_movement_consistency_top: batchMovementConsistency,
    unbatched_out_movements_top: unbatchedOutMovements,
    fx_cost_anomalies_top: fxCostAnomalies,
    uom_factor_anomalies_top: uomFactorAnomalies,
    returned_batches_top: returnedBatches,
    item_flow_summary_top: itemFlowSummary,
  };

  const outPath = path.join(process.cwd(), 'inventory_management_full_audit_report.json');
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2), 'utf8');
  console.log(outPath);
} finally {
  await client.end();
}
