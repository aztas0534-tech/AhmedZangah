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

const isUuid = (s) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(s || ''));
const n = (v) => Number(v || 0) || 0;

const targetItemIds = [
  '98f406f7-631a-480f-997b-5dc1e3fd09d9',
  'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a',
];

const out = {
  generated_at: new Date().toISOString(),
  orphan_batches_deactivated: [],
  sale_cogs_fixed: [],
  stock_after: [],
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

  const orphans = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty,
        sum(case when im.movement_type in ('purchase_in','adjust_in','transfer_in') then im.quantity else 0 end) as inbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      b.warehouse_id::text as warehouse_id,
      b.quantity_received,
      b.quantity_consumed,
      b.unit_cost,
      b.qc_status,
      b.created_at
    from public.batches b
    left join public.purchase_receipts pr on pr.id=b.receipt_id
    left join out_mv o on o.batch_id=b.id::text
    where b.item_id::text = any($1::text[])
      and coalesce(b.status,'active')='active'
      and pr.id is null
      and coalesce(o.inbound_qty,0)=0
      and coalesce(o.outbound_qty,0)=0
      and coalesce(b.quantity_consumed,0)=0
      and coalesce(b.quantity_received,0) <= 2
  `, [targetItemIds])).rows;

  await client.query('begin');
  try {
    await client.query(`set local session_replication_role = 'replica'`);
    for (const b of orphans) {
      await client.query(
        `update public.batches
         set status='inactive',
             quantity_received=0,
             quantity_consumed=0,
             quantity_transferred=0,
             data = coalesce(data,'{}'::jsonb) || jsonb_build_object('manualRepair','deactivated_orphan_batch_no_movements'),
             updated_at=now()
         where id=$1::uuid`,
        [b.batch_id]
      );
      out.orphan_batches_deactivated.push({
        batch_id: b.batch_id,
        item_id: b.item_id,
        old_qty: n(b.quantity_received),
        old_unit_cost: n(b.unit_cost),
      });
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }

  const wrongSales = (await client.query(`
    select
      im.id::text as movement_id,
      im.reference_id::text as order_id,
      im.batch_id::text as batch_id,
      im.item_id::text as item_id,
      im.quantity,
      im.unit_cost as old_unit_cost,
      b.unit_cost as batch_unit_cost
    from public.inventory_movements im
    join public.batches b on b.id=im.batch_id
    where im.movement_type='sale_out'
      and im.reference_table='orders'
      and im.item_id::text='98f406f7-631a-480f-997b-5dc1e3fd09d9'
      and coalesce(im.unit_cost,0) < 1
      and coalesce(b.unit_cost,0) > 1
  `)).rows;

  await client.query('begin');
  try {
    await client.query(`set local session_replication_role = 'replica'`);
    for (const s of wrongSales) {
      const unit = n(s.batch_unit_cost);
      const total = Number((n(s.quantity) * unit).toFixed(6));
      await client.query(
        `update public.inventory_movements
         set unit_cost=$2::numeric,
             total_cost=$3::numeric,
             data=coalesce(data,'{}'::jsonb) || jsonb_build_object('manualRepair','fix_sale_out_unit_cost_from_batch')
         where id=$1::uuid`,
        [s.movement_id, unit, total]
      );
      out.sale_cogs_fixed.push({
        movement_id: s.movement_id,
        order_id: s.order_id,
        item_id: s.item_id,
        qty: n(s.quantity),
        old_unit_cost: n(s.old_unit_cost),
        new_unit_cost: unit,
      });
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }

  for (const s of out.sale_cogs_fixed) {
    try {
      await client.query(`select public.post_inventory_movement($1::uuid)`, [s.movement_id]);
    } catch (e) {
      out.failures.push({ movement_id: s.movement_id, reason: `post_inventory_movement:${String(e?.message || e)}` });
    }
    if (isUuid(s.order_id)) {
      try {
        await client.query(`select public.sync_order_item_cogs_from_sale_out($1::uuid)`, [s.order_id]);
      } catch (e) {
        out.failures.push({ movement_id: s.movement_id, reason: `sync_order_item_cogs:${String(e?.message || e)}` });
      }
    }
  }

  const whRows = (await client.query(`
    select distinct warehouse_id::text as warehouse_id
    from public.stock_management
    where item_id::text = any($1::text[])
  `, [targetItemIds])).rows;
  for (const itemId of targetItemIds) {
    for (const wr of whRows) {
      try {
        await client.query(`select public.recompute_stock_for_item($1::text,$2::uuid)`, [itemId, wr.warehouse_id]);
      } catch (e) {
        out.failures.push({ item_id: itemId, warehouse_id: wr.warehouse_id, reason: `recompute_stock:${String(e?.message || e)}` });
      }
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
    where o.batch_id = b.id
      and b.item_id::text = any($1::text[])
      and abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0))>0.0001
  `, [targetItemIds]);

  out.stock_after = (await client.query(`
    select sm.item_id::text as item_id, sm.warehouse_id::text as warehouse_id,
           sm.available_quantity, sm.qc_hold_quantity, sm.avg_cost
    from public.stock_management sm
    where sm.item_id::text = any($1::text[])
    order by sm.item_id, sm.warehouse_id
  `, [targetItemIds])).rows;
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_two_items_batches_and_cogs_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
