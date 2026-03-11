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

const n = (v) => Number(v || 0) || 0;

const targetItemIds = [
  'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a',
  '2f3a651d-3368-4db3-941f-94f219cc554d',
];

const out = {
  generated_at: new Date().toISOString(),
  before: [],
  inserted_batches: [],
  inserted_movements: [],
  after: [],
  failures: [],
};

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
      set_config('request.jwt.claims',json_build_object('sub',$1::text,'role','authenticated')::text,false),
      set_config('app.allow_ledger_ddl','1',false)`,
    [actor.auth_user_id]
  );

  const before = (await client.query(`
    with so as (
      select im.item_id::text item_id, im.reference_id::text order_id,
             sum(im.quantity) qty_sale, sum(im.total_cost) cost_sale
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='sale_out'
        and im.reference_table='orders'
        and o.status='cancelled'
        and im.item_id::text = any($1::text[])
      group by im.item_id::text, im.reference_id::text
    ),
    ri as (
      select im.item_id::text item_id, im.reference_id::text order_id,
             sum(im.quantity) qty_ret_in, sum(im.total_cost) cost_ret_in
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='return_in'
        and im.reference_table='orders'
        and o.status='cancelled'
        and im.item_id::text = any($1::text[])
      group by im.item_id::text, im.reference_id::text
    )
    select so.item_id, so.order_id, so.qty_sale, coalesce(ri.qty_ret_in,0) qty_ret_in,
           (so.qty_sale-coalesce(ri.qty_ret_in,0)) qty_missing,
           so.cost_sale, coalesce(ri.cost_ret_in,0) cost_ret_in
    from so
    left join ri on ri.item_id=so.item_id and ri.order_id=so.order_id
    where (so.qty_sale-coalesce(ri.qty_ret_in,0)) > 0.0001
    order by so.item_id, so.order_id
  `, [targetItemIds])).rows;
  out.before = before;

  const groups = (await client.query(`
    with base as (
      select
        im.reference_id::text as order_id,
        im.item_id::text as item_id,
        im.warehouse_id::text as warehouse_id,
        coalesce(im.unit_cost,0) as unit_cost,
        sum(im.quantity) as qty_sale,
        sum(im.total_cost) as cost_sale
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='sale_out'
        and im.reference_table='orders'
        and o.status='cancelled'
        and im.item_id::text = any($1::text[])
      group by im.reference_id::text, im.item_id::text, im.warehouse_id::text, coalesce(im.unit_cost,0)
    ),
    ret as (
      select
        im.reference_id::text as order_id,
        im.item_id::text as item_id,
        sum(im.quantity) as qty_ret
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='return_in'
        and im.reference_table='orders'
        and o.status='cancelled'
        and im.item_id::text = any($1::text[])
      group by im.reference_id::text, im.item_id::text
    ),
    roll as (
      select
        b.order_id, b.item_id, b.warehouse_id,
        sum(b.qty_sale) as qty_sale_all,
        sum(b.cost_sale) as cost_sale_all
      from base b
      group by b.order_id, b.item_id, b.warehouse_id
    )
    select
      r.order_id, r.item_id, r.warehouse_id,
      greatest(r.qty_sale_all - coalesce(rt.qty_ret,0), 0) as qty_missing,
      case when r.qty_sale_all > 0 then (r.cost_sale_all / r.qty_sale_all) else 0 end as unit_cost
    from roll r
    left join ret rt on rt.order_id=r.order_id and rt.item_id=r.item_id
    where greatest(r.qty_sale_all - coalesce(rt.qty_ret,0), 0) > 0.0001
    order by r.item_id, r.order_id
  `, [targetItemIds])).rows;

  for (const g of groups) {
    const qty = n(g.qty_missing);
    if (qty <= 0.0001) continue;
    const unitCost = n(g.unit_cost);
    const total = Number((qty * unitCost).toFixed(6));

    await client.query('begin');
    let newBatchId = null;
    let newMovementId = null;
    try {
      const b = (await client.query(
        `insert into public.batches(
           id, item_id, receipt_item_id, receipt_id, warehouse_id, batch_code,
           production_date, expiry_date, quantity_received, quantity_consumed,
           unit_cost, qc_status, status, data
         )
         values (
           gen_random_uuid(), $1::text, null, null, $2::uuid, null,
           null, null, $3::numeric, 0,
           $4::numeric, 'released', 'active',
           jsonb_build_object('source','orders','event','cancelled_repair','orderId',$5::text,'autoRepair',true)
         )
         returning id::text as id`,
        [g.item_id, g.warehouse_id, qty, unitCost, g.order_id]
      )).rows[0];
      newBatchId = b.id;

      const m = (await client.query(
        `insert into public.inventory_movements(
           item_id, movement_type, quantity, unit_cost, total_cost,
           reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
         )
         values (
           $1::text, 'return_in', $2::numeric, $3::numeric, $4::numeric,
           'orders', $5::text, now(), auth.uid(),
           jsonb_build_object('orderId',$5::text,'event','cancelled_repair','autoRepair',true),
           $6::uuid, $7::uuid
         )
         returning id::text as id`,
        [g.item_id, qty, unitCost, total, g.order_id, newBatchId, g.warehouse_id]
      )).rows[0];
      newMovementId = m.id;
      await client.query('commit');
    } catch (e) {
      await client.query('rollback');
      out.failures.push({ order_id: g.order_id, item_id: g.item_id, reason: String(e?.message || e) });
      continue;
    }

    out.inserted_batches.push({
      batch_id: newBatchId,
      order_id: g.order_id,
      item_id: g.item_id,
      warehouse_id: g.warehouse_id,
      qty,
      unit_cost: unitCost,
    });
    out.inserted_movements.push({
      movement_id: newMovementId,
      order_id: g.order_id,
      item_id: g.item_id,
      qty,
      unit_cost: unitCost,
    });

    try {
      await client.query(`select public.post_inventory_movement($1::uuid)`, [newMovementId]);
    } catch (e) {
      out.failures.push({ movement_id: newMovementId, reason: `post_inventory_movement:${String(e?.message || e)}` });
    }
    try {
      await client.query(`select public.recompute_stock_for_item($1::text,$2::uuid)`, [g.item_id, g.warehouse_id]);
    } catch (e) {
      out.failures.push({ item_id: g.item_id, warehouse_id: g.warehouse_id, reason: `recompute_stock:${String(e?.message || e)}` });
    }
  }

  await client.query(`
    with out_mv as (
      select im.batch_id::uuid as batch_id,
             sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::uuid
    )
    update public.batches b
    set quantity_consumed = least(coalesce(b.quantity_received,0), greatest(coalesce(o.outbound_qty,0),0)),
        updated_at = now()
    from out_mv o
    where o.batch_id=b.id
      and b.item_id::text = any($1::text[])
      and abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0))>0.0001
  `, [targetItemIds]);

  const after = (await client.query(`
    with so as (
      select im.item_id::text item_id, im.reference_id::text order_id,
             sum(im.quantity) qty_sale
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='sale_out'
        and im.reference_table='orders'
        and o.status='cancelled'
        and im.item_id::text = any($1::text[])
      group by im.item_id::text, im.reference_id::text
    ),
    ri as (
      select im.item_id::text item_id, im.reference_id::text order_id,
             sum(im.quantity) qty_ret_in
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='return_in'
        and im.reference_table='orders'
        and o.status='cancelled'
        and im.item_id::text = any($1::text[])
      group by im.item_id::text, im.reference_id::text
    )
    select so.item_id, so.order_id, so.qty_sale, coalesce(ri.qty_ret_in,0) qty_ret_in,
           (so.qty_sale-coalesce(ri.qty_ret_in,0)) qty_missing
    from so
    left join ri on ri.item_id=so.item_id and ri.order_id=so.order_id
    where (so.qty_sale-coalesce(ri.qty_ret_in,0)) > 0.0001
    order by so.item_id, so.order_id
  `, [targetItemIds])).rows;
  out.after = after;
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_cancelled_orders_missing_return_in_water_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
