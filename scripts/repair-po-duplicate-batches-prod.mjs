import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const loadEnv = (filePath) => {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    for (const line of raw.split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith('#')) continue;
      const i = t.indexOf('=');
      if (i <= 0) continue;
      const k = t.slice(0, i).trim();
      let v = t.slice(i + 1).trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      if (!process.env[k]) process.env[k] = v;
    }
  } catch {}
};

loadEnv(path.join(process.cwd(), '.env.production'));
loadEnv(path.join(process.cwd(), '.env.local'));

const poRef = String(process.env.PO_REF || 'PO-260226-000009').trim();
const apply = String(process.env.APPLY || '').trim() === '1';

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const q = async (sql, params = []) => (await client.query(sql, params)).rows;
const n = (v) => Number(v || 0) || 0;

await client.connect();

const poRows = await q(
  `select id, po_number, reference_number, warehouse_id, status
   from public.purchase_orders
   where po_number = $1 or reference_number = $1
   order by created_at desc
   limit 1`,
  [poRef]
);
if (poRows.length === 0) {
  console.log(JSON.stringify({ poRef, found: false }, null, 2));
  await client.end();
  process.exit(0);
}
const po = poRows[0];

const receipts = await q(
  `select id, warehouse_id
   from public.purchase_receipts
   where purchase_order_id = $1
   order by created_at asc`,
  [po.id]
);
const receiptIds = receipts.map((x) => x.id);

const receiptItems = receiptIds.length
  ? await q(
    `select id, receipt_id, item_id, quantity, unit_cost, total_cost
     from public.purchase_receipt_items
     where receipt_id = any($1::uuid[])
     order by receipt_id, item_id`,
    [receiptIds]
  )
  : [];

const movementRows = receiptIds.length
  ? await q(
    `select id, item_id, quantity, unit_cost, reference_id, batch_id, warehouse_id
     from public.inventory_movements
     where reference_table='purchase_receipts'
       and reference_id = any($1::text[])
       and movement_type='purchase_in'
     order by occurred_at asc, created_at asc`,
    [receiptIds.map(String)]
  )
  : [];

const batches = receiptIds.length
  ? await q(
    `select id, item_id, receipt_id, warehouse_id, status, qc_status, quantity_received, quantity_consumed, quantity_transferred, unit_cost, created_at
     from public.batches
     where receipt_id = any($1::uuid[])
     order by created_at asc`,
    [receiptIds]
  )
  : [];

const outgoingByBatch = await q(
  `select batch_id, sum(quantity) as out_qty
   from public.inventory_movements
   where batch_id = any($1::uuid[])
     and movement_type in ('sale_out','wastage_out','expired_out','adjust_out','transfer_out','return_out')
   group by batch_id`,
  [batches.map((b) => b.id)]
);
const outMap = new Map(outgoingByBatch.map((r) => [String(r.batch_id), n(r.out_qty)]));

const itemsPlan = [];
for (const pri of receiptItems) {
  const rid = String(pri.receipt_id);
  const itemId = String(pri.item_id);
  const relatedMovements = movementRows.filter((m) => String(m.reference_id) === rid && String(m.item_id) === itemId);
  const canonicalBatchIds = [...new Set(relatedMovements.map((m) => String(m.batch_id || '')).filter(Boolean))];
  const relatedBatches = batches.filter((b) => String(b.receipt_id) === rid && String(b.item_id) === itemId);
  const duplicateCandidates = relatedBatches.filter((b) => !canonicalBatchIds.includes(String(b.id)));
  const unsafeDuplicates = duplicateCandidates.filter((b) => n(b.quantity_consumed) > 0 || n(outMap.get(String(b.id))) > 0);
  const safeDuplicates = duplicateCandidates.filter((b) => !unsafeDuplicates.some((u) => String(u.id) === String(b.id)));
  const mvQty = relatedMovements.reduce((a, m) => a + n(m.quantity), 0);
  const mvCost = relatedMovements.reduce((a, m) => a + n(m.quantity) * n(m.unit_cost), 0);
  const expectedUnitCost = mvQty > 0 ? mvCost / mvQty : n(pri.unit_cost);
  const duplicateQty = safeDuplicates.reduce((a, b) => a + n(b.quantity_received), 0);
  itemsPlan.push({
    receiptItemId: String(pri.id),
    receiptId: rid,
    itemId,
    receiptQty: n(pri.quantity),
    receiptUnitCost: n(pri.unit_cost),
    expectedUnitCost,
    canonicalBatchIds,
    allBatchIds: relatedBatches.map((b) => String(b.id)),
    safeDuplicateBatchIds: safeDuplicates.map((b) => String(b.id)),
    unsafeDuplicateBatchIds: unsafeDuplicates.map((b) => String(b.id)),
    duplicateQty,
  });
}

const hasUnsafe = itemsPlan.some((x) => x.unsafeDuplicateBatchIds.length > 0);
const before = {
  po,
  applyRequested: apply,
  hasUnsafe,
  plan: itemsPlan,
};

if (apply && hasUnsafe) {
  throw new Error('Unsafe duplicate batches detected with consumed/outgoing quantities; aborting repair.');
}

if (apply) {
  await client.query('begin');
  try {
    for (const p of itemsPlan) {
      const expected = n(p.expectedUnitCost);
      await client.query(
        `update public.purchase_receipt_items
         set unit_cost = $2,
             total_cost = round(coalesce(quantity,0) * $2, 6)
         where id = $1::uuid`,
        [p.receiptItemId, expected]
      );

      if (p.canonicalBatchIds.length > 0) {
        await client.query(
          `update public.batches
           set unit_cost = $2,
               updated_at = now()
           where id = any($1::uuid[])`,
          [p.canonicalBatchIds, expected]
        );
      }

      if (p.safeDuplicateBatchIds.length > 0) {
        await client.query(
          `update public.batches
           set status = 'void',
               updated_at = now(),
               data = coalesce(data, '{}'::jsonb) || jsonb_build_object('repair_voided_at', now(), 'repair_reason', 'duplicate_batch_after_receipt')
           where id = any($1::uuid[])`,
          [p.safeDuplicateBatchIds]
        );
      }

      const wh = String(po.warehouse_id);
      await client.query(
        `with is_food as (
           select (coalesce(mi.category,'')='food') as v
           from public.menu_items mi
           where mi.id::text = $1
         )
         update public.stock_management sm
         set available_quantity = coalesce((
               select sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0))
               from public.batches b
               where b.item_id::text = $1
                 and b.warehouse_id = $2::uuid
                 and coalesce(b.status,'active') = 'active'
                 and coalesce(b.qc_status,'') = 'released'
                 and (not coalesce((select v from is_food),false) or b.expiry_date is null or b.expiry_date >= current_date)
             ),0),
             qc_hold_quantity = coalesce((
               select sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0))
               from public.batches b
               where b.item_id::text = $1
                 and b.warehouse_id = $2::uuid
                 and coalesce(b.status,'active') = 'active'
                 and coalesce(b.qc_status,'') in ('pending','quarantined','inspected')
             ),0),
             avg_cost = coalesce((
               select case
                 when sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) > 0
                 then
                   sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) * coalesce(b.unit_cost,0))
                   / sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0))
                 else coalesce(sm.avg_cost,0)
               end
               from public.batches b
               where b.item_id::text = $1
                 and b.warehouse_id = $2::uuid
                 and coalesce(b.status,'active')='active'
             ), coalesce(sm.avg_cost,0)),
             updated_at = now(),
             last_updated = now()
         where sm.item_id::text = $1
           and sm.warehouse_id = $2::uuid`,
        [p.itemId, wh]
      );
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }
}

const after = {
  receipt_items: await q(
    `select receipt_id, item_id, quantity, unit_cost, total_cost
     from public.purchase_receipt_items
     where receipt_id = any($1::uuid[])
     order by receipt_id, item_id`,
    [receiptIds]
  ),
  batches: await q(
    `select id, item_id, receipt_id, status, quantity_received, quantity_consumed, unit_cost
     from public.batches
     where receipt_id = any($1::uuid[])
     order by created_at asc`,
    [receiptIds]
  ),
  stock: await q(
    `select item_id, warehouse_id, available_quantity, qc_hold_quantity, reserved_quantity, avg_cost, updated_at
     from public.stock_management
     where warehouse_id = $1::uuid
       and item_id = any($2::text[])
     order by item_id`,
    [po.warehouse_id, [...new Set(receiptItems.map((x) => String(x.item_id)))]]
  ),
};

await client.end();

const out = { before, applied: apply, after };
const outPath = path.join(process.cwd(), 'backups', `repair_po_${poRef.replace(/[^a-zA-Z0-9_-]/g, '_')}_${apply ? 'applied' : 'dry'}.json`);
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
