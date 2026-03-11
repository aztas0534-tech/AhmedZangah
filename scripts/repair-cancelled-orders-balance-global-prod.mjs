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

const out = {
  generated_at: new Date().toISOString(),
  before_open_rows: 0,
  before_missing_qty: 0,
  before_excess_qty: 0,
  inserted_batches: 0,
  inserted_return_in: 0,
  inserted_sale_out_reversal: 0,
  impacted_items: [],
  failures: [],
  after_open_rows: 0,
  after_missing_qty: 0,
  after_excess_qty: 0,
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
      select im.reference_id::text as order_id, im.item_id::text as item_id, sum(im.quantity) as qty_sale
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='sale_out'
        and im.reference_table='orders'
        and o.status='cancelled'
      group by im.reference_id::text, im.item_id::text
    ),
    ri as (
      select im.reference_id::text as order_id, im.item_id::text as item_id, sum(im.quantity) as qty_ret
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='return_in'
        and im.reference_table='orders'
        and o.status='cancelled'
      group by im.reference_id::text, im.item_id::text
    ),
    d as (
      select
        coalesce(so.order_id, ri.order_id) as order_id,
        coalesce(so.item_id, ri.item_id) as item_id,
        coalesce(so.qty_sale, 0) - coalesce(ri.qty_ret, 0) as net_qty
      from so
      full join ri on ri.order_id=so.order_id and ri.item_id=so.item_id
    )
    select
      count(*) filter (where abs(net_qty) > 0.0001)::int as open_rows,
      coalesce(sum(case when net_qty > 0 then net_qty else 0 end),0)::numeric as missing_qty,
      coalesce(sum(case when net_qty < 0 then -net_qty else 0 end),0)::numeric as excess_qty
    from d
  `)).rows[0];
  out.before_open_rows = Number(before?.open_rows || 0);
  out.before_missing_qty = n(before?.missing_qty);
  out.before_excess_qty = n(before?.excess_qty);

  const needsReturn = (await client.query(`
    with so as (
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
      group by im.reference_id::text, im.item_id::text
    ),
    roll as (
      select
        so.order_id, so.item_id, so.warehouse_id,
        sum(so.qty_sale) as qty_sale_all,
        sum(so.cost_sale) as cost_sale_all
      from so
      group by so.order_id, so.item_id, so.warehouse_id
    )
    select
      r.order_id, r.item_id, r.warehouse_id,
      greatest(r.qty_sale_all - coalesce(rt.qty_ret,0), 0) as qty_missing,
      case when r.qty_sale_all > 0 then (r.cost_sale_all / r.qty_sale_all) else 0 end as unit_cost
    from roll r
    left join ret rt on rt.order_id=r.order_id and rt.item_id=r.item_id
    where greatest(r.qty_sale_all - coalesce(rt.qty_ret,0), 0) > 0.0001
    order by r.item_id, r.order_id
  `)).rows;

  const touched = new Map();
  for (const g of needsReturn) {
    const qty = n(g.qty_missing);
    if (qty <= 0.0001) continue;
    const unitCost = n(g.unit_cost);
    const total = Number((qty * unitCost).toFixed(6));

    await client.query('begin');
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
      out.inserted_batches += 1;

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
        [g.item_id, qty, unitCost, total, g.order_id, b.id, g.warehouse_id]
      )).rows[0];
      await client.query('commit');
      out.inserted_return_in += 1;

      try {
        await client.query(`select public.post_inventory_movement($1::uuid)`, [m.id]);
      } catch (e) {
        out.failures.push({ movement_id: m.id, reason: `post_inventory_movement:${String(e?.message || e)}` });
      }
      const key = `${g.item_id}|${g.warehouse_id}`;
      touched.set(key, { item_id: g.item_id, warehouse_id: g.warehouse_id });
    } catch (e) {
      await client.query('rollback');
      out.failures.push({ order_id: g.order_id, item_id: g.item_id, reason: String(e?.message || e) });
    }
  }

  const needsReversal = (await client.query(`
    with so as (
      select im.reference_id::text as order_id, im.item_id::text as item_id, sum(im.quantity) as qty_sale
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='sale_out'
        and im.reference_table='orders'
        and o.status='cancelled'
      group by im.reference_id::text, im.item_id::text
    ),
    ri as (
      select im.reference_id::text as order_id, im.item_id::text as item_id, sum(im.quantity) as qty_ret
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='return_in'
        and im.reference_table='orders'
        and o.status='cancelled'
      group by im.reference_id::text, im.item_id::text
    )
    select
      coalesce(so.order_id, ri.order_id) as order_id,
      coalesce(so.item_id, ri.item_id) as item_id,
      (coalesce(ri.qty_ret,0) - coalesce(so.qty_sale,0)) as qty_excess
    from so
    full join ri on ri.order_id=so.order_id and ri.item_id=so.item_id
    where (coalesce(ri.qty_ret,0) - coalesce(so.qty_sale,0)) > 0.0001
  `)).rows;

  for (const row of needsReversal) {
    let need = n(row.qty_excess);
    const candidates = (await client.query(
      `select
         im.id::text as movement_id,
         im.batch_id::text as batch_id,
         im.warehouse_id::text as warehouse_id,
         im.quantity, im.unit_cost
       from public.inventory_movements im
       where im.reference_table='orders'
         and im.reference_id::text=$1::text
         and im.item_id::text=$2::text
         and im.movement_type='return_in'
         and (
           coalesce(im.data->>'event','') in ('cancelled_repair','cancelled_repair_reversal')
           or coalesce(im.data->>'autoRepair','false')='true'
         )
       order by im.occurred_at desc`,
      [row.order_id, row.item_id]
    )).rows;

    for (const c of candidates) {
      if (need <= 0.0001) break;
      const qty = Math.min(need, n(c.quantity));
      if (qty <= 0.0001) continue;
      const unitCost = n(c.unit_cost);
      const total = Number((qty * unitCost).toFixed(6));
      try {
        const m = (await client.query(
          `insert into public.inventory_movements(
             item_id, movement_type, quantity, unit_cost, total_cost,
             reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
           )
           values (
             $1::text, 'sale_out', $2::numeric, $3::numeric, $4::numeric,
             'orders', $5::text, now(), auth.uid(),
             jsonb_build_object('orderId',$5::text,'event','cancelled_repair_reversal','sourceMovementId',$6::text,'autoRepair',true),
             $7::uuid, $8::uuid
           )
           returning id::text as id`,
          [row.item_id, qty, unitCost, total, row.order_id, c.movement_id, c.batch_id, c.warehouse_id]
        )).rows[0];
        out.inserted_sale_out_reversal += 1;
        need -= qty;
        try {
          await client.query(`select public.post_inventory_movement($1::uuid)`, [m.id]);
        } catch (e) {
          out.failures.push({ movement_id: m.id, reason: `post_inventory_movement:${String(e?.message || e)}` });
        }
        const key = `${row.item_id}|${c.warehouse_id}`;
        touched.set(key, { item_id: row.item_id, warehouse_id: c.warehouse_id });
      } catch (e) {
        out.failures.push({ order_id: row.order_id, item_id: row.item_id, reason: String(e?.message || e) });
      }
    }
    if (need > 0.0001) {
      out.failures.push({ order_id: row.order_id, item_id: row.item_id, reason: `unresolved_excess_qty=${need}` });
    }
  }

  const impactedItems = [...new Set([...touched.values()].map((x) => String(x.item_id)))];
  out.impacted_items = impactedItems;

  if (touched.size > 0) {
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
      where o.batch_id = b.id
        and b.item_id::text = any($1::text[])
        and abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0))>0.0001
    `, [impactedItems]);

    for (const t of touched.values()) {
      try {
        await client.query(`select public.recompute_stock_for_item($1::text,$2::uuid)`, [t.item_id, t.warehouse_id]);
      } catch (e) {
        out.failures.push({ item_id: t.item_id, warehouse_id: t.warehouse_id, reason: `recompute_stock:${String(e?.message || e)}` });
      }
    }
  }

  const after = (await client.query(`
    with so as (
      select im.reference_id::text as order_id, im.item_id::text as item_id, sum(im.quantity) as qty_sale
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='sale_out'
        and im.reference_table='orders'
        and o.status='cancelled'
      group by im.reference_id::text, im.item_id::text
    ),
    ri as (
      select im.reference_id::text as order_id, im.item_id::text as item_id, sum(im.quantity) as qty_ret
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id::text
      where im.movement_type='return_in'
        and im.reference_table='orders'
        and o.status='cancelled'
      group by im.reference_id::text, im.item_id::text
    ),
    d as (
      select
        coalesce(so.order_id, ri.order_id) as order_id,
        coalesce(so.item_id, ri.item_id) as item_id,
        coalesce(so.qty_sale, 0) - coalesce(ri.qty_ret, 0) as net_qty
      from so
      full join ri on ri.order_id=so.order_id and ri.item_id=so.item_id
    )
    select
      count(*) filter (where abs(net_qty) > 0.0001)::int as open_rows,
      coalesce(sum(case when net_qty > 0 then net_qty else 0 end),0)::numeric as missing_qty,
      coalesce(sum(case when net_qty < 0 then -net_qty else 0 end),0)::numeric as excess_qty
    from d
  `)).rows[0];
  out.after_open_rows = Number(after?.open_rows || 0);
  out.after_missing_qty = n(after?.missing_qty);
  out.after_excess_qty = n(after?.excess_qty);
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_cancelled_orders_balance_global_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
