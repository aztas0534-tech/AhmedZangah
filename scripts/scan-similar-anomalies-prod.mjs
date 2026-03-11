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

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

await client.connect();

const duplicateGroups = await client.query(
  `
  with b as (
    select
      b.receipt_id,
      b.item_id::text as item_id,
      b.warehouse_id,
      count(*) as active_batch_count,
      sum(coalesce(b.quantity_received,0)) as active_qty_received_sum,
      sum(coalesce(b.quantity_consumed,0)) as active_qty_consumed_sum,
      sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) as active_remaining_sum,
      min(b.created_at) as first_batch_at,
      max(b.created_at) as last_batch_at,
      array_agg(b.id order by b.created_at asc) as active_batch_ids
    from public.batches b
    where b.receipt_id is not null
      and coalesce(b.status,'active') = 'active'
    group by b.receipt_id, b.item_id::text, b.warehouse_id
    having count(*) > 1
  ),
  pri as (
    select pri.receipt_id, pri.item_id::text as item_id, sum(coalesce(pri.quantity,0)) as pri_qty, avg(coalesce(pri.unit_cost,0)) as pri_unit_cost
    from public.purchase_receipt_items pri
    group by pri.receipt_id, pri.item_id::text
  ),
  im as (
    select
      im.reference_id::uuid as receipt_id,
      im.item_id::text as item_id,
      sum(coalesce(im.quantity,0)) as im_qty,
      case when sum(coalesce(im.quantity,0)) > 0
        then sum(coalesce(im.quantity,0) * coalesce(im.unit_cost,0)) / sum(coalesce(im.quantity,0))
        else 0 end as im_weighted_unit_cost,
      array_agg(im.batch_id) as movement_batch_ids
    from public.inventory_movements im
    where im.reference_table = 'purchase_receipts'
      and im.movement_type = 'purchase_in'
      and nullif(im.reference_id,'') is not null
    group by im.reference_id::uuid, im.item_id::text
  )
  select
    b.receipt_id,
    b.item_id,
    b.warehouse_id,
    b.active_batch_count,
    b.active_qty_received_sum,
    b.active_qty_consumed_sum,
    b.active_remaining_sum,
    b.first_batch_at,
    b.last_batch_at,
    b.active_batch_ids,
    coalesce(pri.pri_qty,0) as pri_qty,
    coalesce(pri.pri_unit_cost,0) as pri_unit_cost,
    coalesce(im.im_qty,0) as im_qty,
    coalesce(im.im_weighted_unit_cost,0) as im_weighted_unit_cost,
    coalesce(im.movement_batch_ids, '{}') as movement_batch_ids,
    (coalesce(b.active_qty_received_sum,0) - coalesce(im.im_qty,0)) as qty_gap_vs_movement,
    (coalesce(pri.pri_unit_cost,0) - coalesce(im.im_weighted_unit_cost,0)) as unit_cost_gap_pri_vs_movement
  from b
  left join pri on pri.receipt_id = b.receipt_id and pri.item_id = b.item_id
  left join im on im.receipt_id = b.receipt_id and im.item_id = b.item_id
  order by b.last_batch_at desc
  `
);

const suspiciousCostMismatches = await client.query(
  `
  with pri as (
    select
      pri.receipt_id,
      pri.item_id::text as item_id,
      sum(coalesce(pri.quantity,0)) as pri_qty,
      case when sum(coalesce(pri.quantity,0)) > 0
        then sum(coalesce(pri.quantity,0) * coalesce(pri.unit_cost,0)) / sum(coalesce(pri.quantity,0))
        else 0 end as pri_weighted_unit_cost
    from public.purchase_receipt_items pri
    group by pri.receipt_id, pri.item_id::text
  ),
  im as (
    select
      im.reference_id::uuid as receipt_id,
      im.item_id::text as item_id,
      sum(coalesce(im.quantity,0)) as im_qty,
      case when sum(coalesce(im.quantity,0)) > 0
        then sum(coalesce(im.quantity,0) * coalesce(im.unit_cost,0)) / sum(coalesce(im.quantity,0))
        else 0 end as im_weighted_unit_cost
    from public.inventory_movements im
    where im.reference_table = 'purchase_receipts'
      and im.movement_type = 'purchase_in'
      and nullif(im.reference_id,'') is not null
    group by im.reference_id::uuid, im.item_id::text
  ),
  b as (
    select
      b.receipt_id,
      b.item_id::text as item_id,
      sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) as active_remaining_qty,
      case when sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) > 0
        then sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) * coalesce(b.unit_cost,0))
             / sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0))
        else 0 end as active_weighted_batch_cost
    from public.batches b
    where b.receipt_id is not null and coalesce(b.status,'active')='active'
    group by b.receipt_id, b.item_id::text
  )
  select
    pri.receipt_id,
    pri.item_id,
    pri.pri_qty,
    pri.pri_weighted_unit_cost,
    coalesce(im.im_qty,0) as im_qty,
    coalesce(im.im_weighted_unit_cost,0) as im_weighted_unit_cost,
    coalesce(b.active_remaining_qty,0) as active_remaining_qty,
    coalesce(b.active_weighted_batch_cost,0) as active_weighted_batch_cost,
    (coalesce(pri.pri_weighted_unit_cost,0) - coalesce(im.im_weighted_unit_cost,0)) as gap_pri_vs_im,
    (coalesce(b.active_weighted_batch_cost,0) - coalesce(im.im_weighted_unit_cost,0)) as gap_batch_vs_im
  from pri
  left join im on im.receipt_id = pri.receipt_id and im.item_id = pri.item_id
  left join b on b.receipt_id = pri.receipt_id and b.item_id = pri.item_id
  where
      abs(coalesce(pri.pri_weighted_unit_cost,0) - coalesce(im.im_weighted_unit_cost,0)) > greatest(0.01, abs(coalesce(im.im_weighted_unit_cost,0))*0.05)
   or (
      coalesce(b.active_remaining_qty,0) > 0
      and abs(coalesce(b.active_weighted_batch_cost,0) - coalesce(im.im_weighted_unit_cost,0)) > greatest(0.01, abs(coalesce(im.im_weighted_unit_cost,0))*0.05)
   )
  order by greatest(
    abs(coalesce(pri.pri_weighted_unit_cost,0) - coalesce(im.im_weighted_unit_cost,0)),
    abs(coalesce(b.active_weighted_batch_cost,0) - coalesce(im.im_weighted_unit_cost,0))
  ) desc
  limit 1000
  `
);

await client.end();

const duplicateRows = duplicateGroups.rows;
const mismatchRows = suspiciousCostMismatches.rows;

const summary = {
  scannedAt: new Date().toISOString(),
  duplicateActiveReceiptItemGroups: duplicateRows.length,
  duplicateGroupsWithQtyInflation: duplicateRows.filter((r) => Number(r.qty_gap_vs_movement || 0) > 1e-6).length,
  suspiciousCostMismatchGroups: mismatchRows.length,
};

const report = {
  summary,
  duplicateActiveGroups: duplicateRows,
  suspiciousCostMismatches: mismatchRows,
};

const outPath = path.join(process.cwd(), 'backups', `similar_anomalies_scan_${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
fs.writeFileSync(outPath, JSON.stringify(report, null, 2), 'utf8');
console.log(outPath);
