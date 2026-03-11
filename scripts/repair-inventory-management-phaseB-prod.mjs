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

const out = {
  generated_at: new Date().toISOString(),
  bad_before_count: 0,
  mismatched_returns_count: 0,
  planned_moves: [],
  applied_moves: [],
  failed_moves: [],
  bad_after_count: 0,
};

const toNum = (v) => Number(v || 0) || 0;

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

  const badBefore = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select b.id::text as batch_id, b.item_id::text, b.warehouse_id::text, b.quantity_received, coalesce(o.outbound_qty,0) as outbound_qty,
           (coalesce(b.quantity_received,0)-coalesce(o.outbound_qty,0)) as capacity
    from public.batches b
    left join out_mv o on o.batch_id=b.id::text
    where coalesce(b.status,'active')='active'
      and (coalesce(b.quantity_received,0)-coalesce(o.outbound_qty,0)) < -0.0001
  `)).rows;
  out.bad_before_count = badBefore.length;

  const affectedItems = [...new Set(badBefore.map((r) => String(r.item_id)))];
  const affectedWh = [...new Set(badBefore.map((r) => String(r.warehouse_id)))];

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
      (coalesce(b.quantity_received,0)-coalesce(o.outbound_qty,0)) as capacity,
      pr.purchase_order_id::text as po_id
    from public.batches b
    left join out_mv o on o.batch_id=b.id::text
    left join public.purchase_receipts pr on pr.id=b.receipt_id
    where b.item_id::text = any($1::text[])
      and b.warehouse_id::text = any($2::text[])
      and coalesce(b.status,'active')='active'
  `, [affectedItems, affectedWh])).rows;

  const movements = (await client.query(`
    select
      im.id::text as movement_id,
      im.movement_type,
      im.item_id::text as item_id,
      im.warehouse_id::text as warehouse_id,
      im.batch_id::text as batch_id,
      im.quantity,
      im.reference_table,
      im.reference_id,
      im.occurred_at,
      im.data
    from public.inventory_movements im
    where im.item_id::text = any($1::text[])
      and im.warehouse_id::text = any($2::text[])
      and im.batch_id is not null
      and im.movement_type in ('sale_out','return_out')
    order by im.occurred_at asc
  `, [affectedItems, affectedWh])).rows;

  const batchById = new Map(batches.map((b) => [String(b.batch_id), { ...b, capacity: toNum(b.capacity) }]));
  const movementById = new Map(movements.map((m) => [String(m.movement_id), { ...m, quantity: toNum(m.quantity) }]));

  const mismatchedReturns = movements.filter((m) => {
    if (String(m.movement_type) !== 'return_out') return false;
    const po = String((m.data || {}).purchaseOrderId || '');
    if (!po) return false;
    const b = batchById.get(String(m.batch_id));
    return !!b && String(b.po_id || '') !== po;
  });
  out.mismatched_returns_count = mismatchedReturns.length;

  const chooseAltBatchForSale = (saleMv, avoidBatchId) => {
    const candidates = batches
      .map((b) => batchById.get(String(b.batch_id)))
      .filter(Boolean)
      .filter((b) =>
        String(b.item_id) === String(saleMv.item_id) &&
        String(b.warehouse_id) === String(saleMv.warehouse_id) &&
        String(b.batch_id) !== String(avoidBatchId) &&
        String(b.status || 'active') === 'active' &&
        String(b.qc_status || 'released') === 'released' &&
        toNum(b.capacity) >= toNum(saleMv.quantity)
      )
      .sort((a, b) => toNum(b.capacity) - toNum(a.capacity));
    return candidates[0] || null;
  };

  const registerMove = (movementId, fromBatchId, toBatchId, reason) => {
    out.planned_moves.push({ movement_id: movementId, from_batch_id: fromBatchId, to_batch_id: toBatchId, reason });
    const mv = movementById.get(String(movementId));
    if (!mv) return;
    const from = batchById.get(String(fromBatchId));
    const to = batchById.get(String(toBatchId));
    if (from) from.capacity += toNum(mv.quantity);
    if (to) to.capacity -= toNum(mv.quantity);
    mv.batch_id = String(toBatchId);
  };

  for (const ret of mismatchedReturns) {
    const desiredPo = String((ret.data || {}).purchaseOrderId || '');
    const target = batches
      .map((b) => batchById.get(String(b.batch_id)))
      .filter(Boolean)
      .filter((b) =>
        String(b.item_id) === String(ret.item_id) &&
        String(b.warehouse_id) === String(ret.warehouse_id) &&
        String(b.po_id || '') === desiredPo &&
        String(b.status || 'active') === 'active'
      )
      .sort((a, b) => toNum(b.capacity) - toNum(a.capacity))[0];
    if (!target) {
      out.failed_moves.push({ movement_id: ret.movement_id, reason: 'NO_TARGET_BATCH_SAME_PO' });
      continue;
    }

    while (toNum(target.capacity) + 1e-9 < toNum(ret.quantity)) {
      const salesOnTarget = [...movementById.values()]
        .filter((m) =>
          String(m.movement_type) === 'sale_out' &&
          String(m.batch_id) === String(target.batch_id) &&
          String(m.item_id) === String(target.item_id) &&
          String(m.warehouse_id) === String(target.warehouse_id)
        )
        .sort((a, b) => toNum(a.quantity) - toNum(b.quantity));
      if (!salesOnTarget.length) break;
      let movedOne = false;
      for (const sale of salesOnTarget) {
        const alt = chooseAltBatchForSale(sale, target.batch_id);
        if (!alt) continue;
        registerMove(sale.movement_id, target.batch_id, alt.batch_id, 'free_capacity_for_same_po_purchase_return');
        movedOne = true;
        if (toNum(target.capacity) + 1e-9 >= toNum(ret.quantity)) break;
      }
      if (!movedOne) break;
    }

    if (toNum(target.capacity) + 1e-9 < toNum(ret.quantity)) {
      out.failed_moves.push({ movement_id: ret.movement_id, reason: 'INSUFFICIENT_CAPACITY_AFTER_SALE_REALLOC', target_batch_id: target.batch_id });
      continue;
    }
    registerMove(ret.movement_id, ret.batch_id, target.batch_id, 'align_purchase_return_to_same_po_batch');
  }

  const badAfterPlan = () => {
    const bad = [];
    for (const b of batchById.values()) {
      if (toNum(b.capacity) < -0.0001) bad.push(b);
    }
    return bad;
  };

  for (const b of badAfterPlan()) {
    const shortage = Math.abs(toNum(b.capacity));
    let need = shortage;
    const sales = [...movementById.values()]
      .filter((m) => String(m.movement_type) === 'sale_out' && String(m.batch_id) === String(b.batch_id))
      .sort((x, y) => toNum(x.quantity) - toNum(y.quantity));
    for (const sale of sales) {
      if (need <= 0.0001) break;
      const alt = chooseAltBatchForSale(sale, b.batch_id);
      if (!alt) continue;
      registerMove(sale.movement_id, b.batch_id, alt.batch_id, 'resolve_negative_batch_capacity_after_phaseA');
      need -= toNum(sale.quantity);
    }
    if (need > 0.0001) {
      out.failed_moves.push({ batch_id: b.batch_id, reason: 'UNRESOLVED_NEGATIVE_CAPACITY', remaining_shortage: need });
    }
  }

  await client.query('begin');
  try {
    await client.query(`set local session_replication_role = 'replica'`);
    for (const mv of out.planned_moves) {
      await client.query(
        `update public.inventory_movements
         set batch_id = $2::uuid,
             data = coalesce(data,'{}'::jsonb) || jsonb_build_object('batchId',$2::text,'phase2Reallocated',true,'phase2Reason',$3::text)
         where id = $1::uuid`,
        [mv.movement_id, mv.to_batch_id, mv.reason]
      );
      out.applied_moves.push(mv);
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }

  const badAfter = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select count(*) as c
    from public.batches b
    left join out_mv o on o.batch_id=b.id::text
    where coalesce(b.status,'active')='active'
      and (coalesce(b.quantity_received,0)-coalesce(o.outbound_qty,0)) < -0.0001
  `)).rows[0]?.c;
  out.bad_after_count = Number(badAfter || 0);
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_inventory_management_phaseB_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
