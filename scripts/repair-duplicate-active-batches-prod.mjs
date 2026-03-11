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

const reportPath = String(process.env.REPORT_JSON || '').trim();
if (!reportPath) throw new Error('REPORT_JSON is required');
const apply = String(process.env.APPLY || '').trim() === '1';

const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const groups = (report.duplicateActiveGroups || []).filter((g) => Number(g.qty_gap_vs_movement || 0) > 1e-9);

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

const plan = [];
for (const g of groups) {
  const receiptId = String(g.receipt_id);
  const itemId = String(g.item_id);
  const warehouseId = String(g.warehouse_id);
  const active = await q(
    `select id, created_at
     from public.batches
     where receipt_id = $1
       and item_id::text = $2
       and coalesce(status,'active')='active'
     order by created_at asc`,
    [receiptId, itemId]
  );
  if (active.length <= 1) continue;
  const activeIds = active.map((x) => String(x.id));
  const movementIds = (g.movement_batch_ids || []).map((x) => String(x)).filter((id) => activeIds.includes(id));
  const keepIds = movementIds.length ? movementIds : [String(active[0].id)];
  const voidIds = activeIds.filter((id) => !keepIds.includes(id));
  if (!voidIds.length) continue;
  plan.push({ receiptId, itemId, warehouseId, keepIds, voidIds });
}

const applied = {
  apply,
  groupsInReport: groups.length,
  plannedGroups: plan.length,
  voidedBatches: 0,
  recalculatedStocks: 0,
  details: [],
};

if (apply && plan.length) {
  try {
    await client.query('begin');
    for (const p of plan) {
      const vr = await client.query(
        `update public.batches
         set status = 'void'
         where id = any($1::uuid[])`,
        [p.voidIds]
      );
      applied.voidedBatches += vr.rowCount || 0;

      const sr = await client.query(
        `update public.stock_management sm
         set available_quantity = coalesce(s.qty, 0),
             avg_cost = coalesce(s.avg_cost, 0),
             updated_at = now(),
             last_updated = now()
         from (
           select
             b.item_id::text as item_id,
             b.warehouse_id,
             sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) as qty,
             case
               when sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) > 0
               then sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) * coalesce(b.unit_cost,0))
                    / sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0))
               else 0
             end as avg_cost
           from public.batches b
           where b.item_id::text = $1
             and b.warehouse_id = $2::uuid
             and coalesce(b.status,'active')='active'
           group by b.item_id::text, b.warehouse_id
         ) s
         where sm.item_id::text = s.item_id
           and sm.warehouse_id = s.warehouse_id`,
        [p.itemId, p.warehouseId]
      );
      applied.recalculatedStocks += sr.rowCount || 0;
      applied.details.push(p);
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }
}

const after = [];
for (const p of plan) {
  const rows = await q(
    `select id, status, quantity_received, quantity_consumed, quantity_transferred, unit_cost, created_at
     from public.batches
     where receipt_id = $1
       and item_id::text = $2
     order by created_at asc`,
    [p.receiptId, p.itemId]
  );
  after.push({ receiptId: p.receiptId, itemId: p.itemId, rows });
}

await client.end();

const out = { reportPath, applied, after };
const outPath = path.join(
  process.cwd(),
  'backups',
  `repair_duplicate_active_batches_${apply ? 'applied' : 'dry'}_${new Date().toISOString().replace(/[:.]/g, '-')}.json`
);
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
