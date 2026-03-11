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

const toNum = (v) => Number(v || 0) || 0;

const out = {
  generated_at: new Date().toISOString(),
  mismatched_before_count: 0,
  planned_moves: [],
  applied_moves: [],
  failed_moves: [],
  mismatched_after_count: 0,
  bad_batch_after_count: 0,
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

  const mismatchedReturns = (await client.query(`
    select
      im.id::text as movement_id,
      im.item_id::text as item_id,
      im.warehouse_id::text as warehouse_id,
      im.batch_id::text as batch_id,
      im.quantity,
      im.occurred_at,
      im.data->>'purchaseOrderId' as movement_po,
      pr.purchase_order_id::text as batch_po
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    left join public.purchase_receipts pr on pr.id = b.receipt_id
    where im.movement_type = 'return_out'
      and im.reference_table = 'purchase_returns'
      and coalesce(im.data->>'purchaseOrderId','') <> ''
      and coalesce(pr.purchase_order_id::text,'') <> ''
      and (im.data->>'purchaseOrderId') <> pr.purchase_order_id::text
    order by im.occurred_at asc, im.id asc
  `)).rows.map((r) => ({ ...r, quantity: toNum(r.quantity) }));
  out.mismatched_before_count = mismatchedReturns.length;

  if (mismatchedReturns.length === 0) {
    const outPath0 = path.join(process.cwd(), 'repair_inventory_management_phase21_result.json');
    fs.writeFileSync(outPath0, JSON.stringify(out, null, 2), 'utf8');
    console.log(outPath0);
    process.exit(0);
  }

  const affectedItems = [...new Set(mismatchedReturns.map((r) => String(r.item_id)))];
  const affectedWh = [...new Set(mismatchedReturns.map((r) => String(r.warehouse_id)))];
  const affectedPos = [...new Set(mismatchedReturns.map((r) => String(r.movement_po)))];

  const batches = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
             sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      b.warehouse_id::text as warehouse_id,
      coalesce(b.status,'active') as status,
      coalesce(b.qc_status,'released') as qc_status,
      b.created_at,
      coalesce(b.quantity_received,0) as quantity_received,
      coalesce(o.outbound_qty,0) as outbound_qty,
      (coalesce(b.quantity_received,0) - coalesce(o.outbound_qty,0)) as capacity,
      pr.purchase_order_id::text as po_id
    from public.batches b
    left join out_mv o on o.batch_id = b.id::text
    left join public.purchase_receipts pr on pr.id = b.receipt_id
    where b.item_id::text = any($1::text[])
      and b.warehouse_id::text = any($2::text[])
      and coalesce(b.status,'active') = 'active'
  `, [affectedItems, affectedWh])).rows.map((b) => ({ ...b, capacity: toNum(b.capacity) }));

  const sales = (await client.query(`
    select
      im.id::text as movement_id,
      im.item_id::text as item_id,
      im.warehouse_id::text as warehouse_id,
      im.batch_id::text as batch_id,
      im.quantity,
      im.occurred_at
    from public.inventory_movements im
    where im.movement_type = 'sale_out'
      and im.batch_id is not null
      and im.item_id::text = any($1::text[])
      and im.warehouse_id::text = any($2::text[])
    order by im.occurred_at asc, im.id asc
  `, [affectedItems, affectedWh])).rows.map((s) => ({ ...s, quantity: toNum(s.quantity) }));

  const batchById = new Map(batches.map((b) => [String(b.batch_id), b]));
  const salesByBatch = new Map();
  for (const s of sales) {
    const k = String(s.batch_id);
    const arr = salesByBatch.get(k) || [];
    arr.push(s);
    salesByBatch.set(k, arr);
  }

  const pickAltForSale = (sale, avoidBatchId) => {
    const candidates = batches
      .filter((b) =>
        String(b.item_id) === String(sale.item_id) &&
        String(b.warehouse_id) === String(sale.warehouse_id) &&
        String(b.batch_id) !== String(avoidBatchId) &&
        String(b.status || 'active') === 'active' &&
        String(b.qc_status || 'released') === 'released' &&
        toNum(b.capacity) >= toNum(sale.quantity)
      )
      .sort((a, b) => toNum(b.capacity) - toNum(a.capacity));
    return candidates[0] || null;
  };

  const planMove = (movementId, fromBatchId, toBatchId, reason) => {
    out.planned_moves.push({ movement_id: movementId, from_batch_id: fromBatchId, to_batch_id: toBatchId, reason });
    const from = batchById.get(String(fromBatchId));
    const to = batchById.get(String(toBatchId));
    const qty = (() => {
      const r = mismatchedReturns.find((m) => String(m.movement_id) === String(movementId));
      if (r) return toNum(r.quantity);
      const s = sales.find((m) => String(m.movement_id) === String(movementId));
      if (s) return toNum(s.quantity);
      return 0;
    })();
    if (from) from.capacity += qty;
    if (to) to.capacity -= qty;
  };

  for (const ret of mismatchedReturns) {
    const targetPool = batches
      .filter((b) =>
        String(b.item_id) === String(ret.item_id) &&
        String(b.warehouse_id) === String(ret.warehouse_id) &&
        String(b.po_id || '') === String(ret.movement_po || '') &&
        String(b.status || 'active') === 'active'
      )
      .sort((a, b) => toNum(b.capacity) - toNum(a.capacity));
    const target = targetPool[0];
    if (!target) {
      out.failed_moves.push({ movement_id: ret.movement_id, reason: 'NO_TARGET_BATCH_FOR_PO', po: ret.movement_po });
      continue;
    }

    let need = Math.max(0, toNum(ret.quantity) - toNum(target.capacity));
    if (need > 0.0001) {
      const salesOnTarget = (salesByBatch.get(String(target.batch_id)) || []).sort((x, y) => toNum(x.quantity) - toNum(y.quantity));
      for (const s of salesOnTarget) {
        if (need <= 0.0001) break;
        const alt = pickAltForSale(s, target.batch_id);
        if (!alt) continue;
        planMove(s.movement_id, target.batch_id, alt.batch_id, 'free_capacity_for_purchase_return_po_alignment');
        need -= toNum(s.quantity);
      }
    }

    if (toNum(target.capacity) + 1e-9 < toNum(ret.quantity)) {
      out.failed_moves.push({
        movement_id: ret.movement_id,
        reason: 'INSUFFICIENT_TARGET_CAPACITY',
        target_batch_id: target.batch_id,
        need_qty: ret.quantity,
        target_capacity: target.capacity,
      });
      continue;
    }

    planMove(ret.movement_id, ret.batch_id, target.batch_id, 'align_purchase_return_with_same_po_batch');
  }

  await client.query('begin');
  try {
    await client.query(`set local session_replication_role = 'replica'`);
    for (const m of out.planned_moves) {
      await client.query(
        `update public.inventory_movements
         set batch_id = $2::uuid,
             data = coalesce(data,'{}'::jsonb) || jsonb_build_object('batchId',$2::text,'phase21Reallocated',true,'phase21Reason',$3::text)
         where id = $1::uuid`,
        [m.movement_id, m.to_batch_id, m.reason]
      );
      out.applied_moves.push(m);
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }

  const mismatchAfter = (await client.query(`
    select count(*)::int as c
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    left join public.purchase_receipts pr on pr.id = b.receipt_id
    where im.movement_type = 'return_out'
      and im.reference_table = 'purchase_returns'
      and coalesce(im.data->>'purchaseOrderId','') <> ''
      and coalesce(pr.purchase_order_id::text,'') <> ''
      and (im.data->>'purchaseOrderId') <> pr.purchase_order_id::text
  `)).rows[0]?.c;
  out.mismatched_after_count = Number(mismatchAfter || 0);

  const badAfter = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
             sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select count(*)::int as c
    from public.batches b
    left join out_mv o on o.batch_id = b.id::text
    where coalesce(b.status,'active')='active'
      and abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0)) > 0.0001
  `)).rows[0]?.c;
  out.bad_batch_after_count = Number(badAfter || 0);
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_inventory_management_phase21_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
