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

const parseCsv = (text) => {
  const rows = [];
  let i = 0;
  let field = '';
  let row = [];
  let inQ = false;
  const pushField = () => {
    row.push(field);
    field = '';
  };
  const pushRow = () => {
    rows.push(row);
    row = [];
  };
  while (i < text.length) {
    const c = text[i];
    if (inQ) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 2;
          continue;
        }
        inQ = false;
        i += 1;
        continue;
      }
      field += c;
      i += 1;
      continue;
    }
    if (c === '"') {
      inQ = true;
      i += 1;
      continue;
    }
    if (c === ',') {
      pushField();
      i += 1;
      continue;
    }
    if (c === '\n') {
      pushField();
      pushRow();
      i += 1;
      continue;
    }
    if (c === '\r') {
      i += 1;
      continue;
    }
    field += c;
    i += 1;
  }
  if (field.length > 0 || row.length > 0) {
    pushField();
    pushRow();
  }
  return rows;
};

const num = (v) => Number(v ?? 0) || 0;

loadEnv(path.join(process.cwd(), '.env.production'));
loadEnv(path.join(process.cwd(), '.env.local'));

const reportCsvPath = String(process.env.REPORT_CSV || path.join(process.cwd(), 'backups', 'تقرير_فروقات_الدفعات_حسب_الأولوية_2026-03-11T20-29-53-159Z.csv')).trim();
const apply = String(process.env.APPLY || '').trim() === '1';

const rawCsv = fs.readFileSync(reportCsvPath, 'utf8');
const csvRows = parseCsv(rawCsv);
if (csvRows.length < 2) throw new Error('empty report');
const headers = csvRows[0];
const records = csvRows.slice(1).map((r) => {
  const o = {};
  headers.forEach((h, idx) => {
    o[h] = r[idx] ?? '';
  });
  return o;
});

const targetRows = records.filter((r) => {
  const priority = String(r['الأولوية']);
  const isActive = String(r['حالة_الدفعة']) === 'active';
  const significant = String(r['فجوة_مهمة']) === 'true';
  const shouldRepair = priority === 'حرج' || priority === 'متوسط' || significant;
  return shouldRepair &&
    isActive &&
    String(r['معرف_الدفعة']).length > 0 &&
    String(r['معرف_الاستلام']).length > 0 &&
    String(r['معرف_الصنف']).length > 0;
});

const grouped = new Map();
for (const r of targetRows) {
  const receiptId = String(r['معرف_الاستلام']);
  const itemId = String(r['معرف_الصنف']);
  const key = `${receiptId}__${itemId}`;
  const prev = grouped.get(key) || {
    receiptId,
    itemId,
    warehouseId: String(r['معرف_المخزن']),
    priorities: new Set(),
    batchIdsFromReport: new Set(),
  };
  prev.priorities.add(String(r['الأولوية']));
  prev.batchIdsFromReport.add(String(r['معرف_الدفعة']));
  grouped.set(key, prev);
}

const targets = [...grouped.values()].map((x) => ({
  ...x,
  priorities: [...x.priorities],
  batchIdsFromReport: [...x.batchIdsFromReport],
}));

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const q = async (sql, params = []) => (await client.query(sql, params)).rows;
await client.connect();

const receiptIds = [...new Set(targets.map((t) => t.receiptId))];
const itemIds = [...new Set(targets.map((t) => t.itemId))];
const whPairs = [...new Set(targets.map((t) => `${t.itemId}__${t.warehouseId}`))].map((k) => {
  const [itemId, warehouseId] = k.split('__');
  return { itemId, warehouseId };
});

const before = {
  targetRowsCount: targetRows.length,
  targetGroupsCount: targets.length,
  targets,
  receiptItems: receiptIds.length ? await q(
    `select receipt_id, item_id, quantity, unit_cost, total_cost
     from public.purchase_receipt_items
     where receipt_id = any($1::uuid[])
       and item_id::text = any($2::text[])
     order by receipt_id, item_id`,
    [receiptIds, itemIds]
  ) : [],
  batches: receiptIds.length ? await q(
    `select id, receipt_id, item_id, warehouse_id, status, quantity_received, quantity_consumed, quantity_transferred, unit_cost, created_at
     from public.batches
     where receipt_id = any($1::uuid[])
       and item_id::text = any($2::text[])
     order by created_at asc`,
    [receiptIds, itemIds]
  ) : [],
  purchaseInMovements: receiptIds.length ? await q(
    `select
       im.reference_id::uuid as receipt_id,
       im.item_id::text as item_id,
       sum(coalesce(im.quantity,0)) as qty,
       case when sum(coalesce(im.quantity,0)) > 0
            then sum(coalesce(im.quantity,0) * coalesce(im.unit_cost,0)) / sum(coalesce(im.quantity,0))
            else 0 end as expected_unit_cost,
       array_agg(im.batch_id) filter (where im.batch_id is not null) as movement_batch_ids
     from public.inventory_movements im
     where im.reference_table='purchase_receipts'
       and im.movement_type='purchase_in'
       and im.reference_id::uuid = any($1::uuid[])
       and im.item_id::text = any($2::text[])
     group by im.reference_id::uuid, im.item_id::text`,
    [receiptIds, itemIds]
  ) : [],
  stock: whPairs.length ? await q(
    `select sm.item_id::text as item_id, sm.warehouse_id, sm.available_quantity, sm.avg_cost
     from public.stock_management sm
     where (sm.item_id::text, sm.warehouse_id) in (
       select x.item_id, x.warehouse_id
       from jsonb_to_recordset($1::jsonb) as x(item_id text, warehouse_id uuid)
     )
     order by sm.item_id, sm.warehouse_id`,
    [JSON.stringify(whPairs)]
  ) : [],
};

const movementByKey = new Map(
  before.purchaseInMovements.map((m) => [`${m.receipt_id}__${m.item_id}`, m])
);

const plan = [];
for (const t of targets) {
  const key = `${t.receiptId}__${t.itemId}`;
  const m = movementByKey.get(key);
  if (!m) continue;
  const expectedUnitCost = num(m.expected_unit_cost);
  const movementBatchIds = (m.movement_batch_ids || []).map((x) => String(x));
  plan.push({
    ...t,
    expectedUnitCost,
    movementBatchIds,
  });
}

const applied = {
  apply,
  touchedGroups: [],
  updatedReceiptItems: 0,
  updatedActiveBatchesCost: 0,
  voidedDuplicateBatches: 0,
  recalculatedStocks: 0,
  skippedNoMovement: targets.length - plan.length,
};

if (apply && plan.length) {
  try {
    await client.query('begin');
    for (const p of plan) {
      const priRes = await client.query(
        `update public.purchase_receipt_items
         set unit_cost = $3,
             total_cost = round(coalesce(quantity,0) * $3, 6)
         where receipt_id = $1
           and item_id::text = $2`,
        [p.receiptId, p.itemId, p.expectedUnitCost]
      );
      applied.updatedReceiptItems += priRes.rowCount || 0;

      const batchCostRes = await client.query(
        `update public.batches
         set unit_cost = $3
         where receipt_id = $1
           and item_id::text = $2
           and coalesce(status,'active')='active'`,
        [p.receiptId, p.itemId, p.expectedUnitCost]
      );
      applied.updatedActiveBatchesCost += batchCostRes.rowCount || 0;

      const activeBatches = await q(
        `select id, created_at
         from public.batches
         where receipt_id = $1
           and item_id::text = $2
           and coalesce(status,'active')='active'
         order by created_at asc`,
        [p.receiptId, p.itemId]
      );

      if (activeBatches.length > 1) {
        const activeIds = activeBatches.map((b) => String(b.id));
        const keepByMovement = p.movementBatchIds.filter((id) => activeIds.includes(id));
        const keepIds = keepByMovement.length ? keepByMovement : [String(activeBatches[0].id)];
        const voidIds = activeIds.filter((id) => !keepIds.includes(id));
        if (voidIds.length) {
          const voidRes = await client.query(
            `update public.batches
             set status = 'void'
             where id = any($1::uuid[])`,
            [voidIds]
          );
          applied.voidedDuplicateBatches += voidRes.rowCount || 0;
        }
      }

      const stockRes = await client.query(
        `update public.stock_management sm
         set available_quantity = coalesce(s.qty, 0),
             avg_cost = coalesce(s.avg_cost, 0),
             updated_at = now(),
             last_updated = now()
         from (
           select
             b.item_id::text as item_id,
             b.warehouse_id,
             sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)) as qty,
             case
               when sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)) > 0
               then sum(
                 greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) * coalesce(b.unit_cost,0)
               ) / sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0))
               else 0
             end as avg_cost
           from public.batches b
           where b.item_id::text = $1
             and b.warehouse_id = $2::uuid
             and coalesce(b.status, 'active') = 'active'
           group by b.item_id::text, b.warehouse_id
         ) s
         where sm.item_id::text = s.item_id
           and sm.warehouse_id = s.warehouse_id`,
        [p.itemId, p.warehouseId]
      );
      applied.recalculatedStocks += stockRes.rowCount || 0;
      applied.touchedGroups.push({
        receiptId: p.receiptId,
        itemId: p.itemId,
        expectedUnitCost: p.expectedUnitCost,
      });
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }
}

const after = {
  receiptItems: receiptIds.length ? await q(
    `select receipt_id, item_id, quantity, unit_cost, total_cost
     from public.purchase_receipt_items
     where receipt_id = any($1::uuid[])
       and item_id::text = any($2::text[])
     order by receipt_id, item_id`,
    [receiptIds, itemIds]
  ) : [],
  batches: receiptIds.length ? await q(
    `select id, receipt_id, item_id, warehouse_id, status, quantity_received, quantity_consumed, quantity_transferred, unit_cost, created_at
     from public.batches
     where receipt_id = any($1::uuid[])
       and item_id::text = any($2::text[])
     order by created_at asc`,
    [receiptIds, itemIds]
  ) : [],
  stock: whPairs.length ? await q(
    `select sm.item_id::text as item_id, sm.warehouse_id, sm.available_quantity, sm.avg_cost
     from public.stock_management sm
     where (sm.item_id::text, sm.warehouse_id) in (
       select x.item_id, x.warehouse_id
       from jsonb_to_recordset($1::jsonb) as x(item_id text, warehouse_id uuid)
     )
     order by sm.item_id, sm.warehouse_id`,
    [JSON.stringify(whPairs)]
  ) : [],
};

await client.end();

const out = { reportCsvPath, before, plan, applied, after };
const outPath = path.join(
  process.cwd(),
  'backups',
  `repair_from_priority_report_${apply ? 'applied' : 'dry'}_${new Date().toISOString().replace(/[:.]/g, '-')}.json`
);
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
