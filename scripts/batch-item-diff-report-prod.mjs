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

const asNum = (v) => Number(v ?? 0) || 0;
const q = (v) => `"${String(v ?? '').replaceAll('"', '""')}"`;

await client.connect();

const res = await client.query(
  `
  with im_ref as (
    select
      im.reference_id::uuid as receipt_id,
      im.item_id::text as item_id,
      avg(coalesce(im.unit_cost,0)) filter (where im.movement_type='purchase_in') as im_unit_cost_avg,
      case when sum(coalesce(im.quantity,0)) filter (where im.movement_type='purchase_in') > 0
        then
          sum(coalesce(im.quantity,0) * coalesce(im.unit_cost,0)) filter (where im.movement_type='purchase_in')
          / sum(coalesce(im.quantity,0)) filter (where im.movement_type='purchase_in')
        else 0 end as im_unit_cost_weighted
    from public.inventory_movements im
    where im.reference_table = 'purchase_receipts'
      and im.movement_type = 'purchase_in'
      and nullif(im.reference_id,'') is not null
    group by im.reference_id::uuid, im.item_id::text
  )
  select
    b.id as batch_id,
    b.receipt_id,
    pr.purchase_order_id,
    po.po_number,
    po.reference_number as po_reference,
    b.item_id::text as item_id,
    b.warehouse_id,
    coalesce(b.status,'active') as batch_status,
    coalesce(b.qc_status,'') as qc_status,
    b.created_at as batch_created_at,
    coalesce(b.quantity_received,0) as quantity_received,
    coalesce(b.quantity_consumed,0) as quantity_consumed,
    coalesce(b.quantity_transferred,0) as quantity_transferred,
    greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) as remaining_qty,
    coalesce(b.unit_cost,0) as batch_unit_cost,
    coalesce(pri.unit_cost,0) as receipt_unit_cost,
    coalesce(imr.im_unit_cost_weighted,0) as movement_unit_cost,
    (coalesce(b.unit_cost,0) - coalesce(pri.unit_cost,0)) as diff_batch_vs_receipt_unit,
    (coalesce(b.unit_cost,0) - coalesce(imr.im_unit_cost_weighted,0)) as diff_batch_vs_movement_unit,
    (coalesce(pri.unit_cost,0) - coalesce(imr.im_unit_cost_weighted,0)) as diff_receipt_vs_movement_unit,
    (greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) * (coalesce(b.unit_cost,0) - coalesce(imr.im_unit_cost_weighted,0))) as diff_batch_vs_movement_total_on_remaining
  from public.batches b
  left join public.purchase_receipts pr on pr.id = b.receipt_id
  left join public.purchase_orders po on po.id = pr.purchase_order_id
  left join public.purchase_receipt_items pri on pri.receipt_id = b.receipt_id and pri.item_id::text = b.item_id::text
  left join im_ref imr on imr.receipt_id = b.receipt_id and imr.item_id = b.item_id::text
  where b.receipt_id is not null
  order by abs((coalesce(b.unit_cost,0) - coalesce(imr.im_unit_cost_weighted,0))) desc, b.created_at desc
  `
);

await client.end();

const rows = res.rows.map((r) => {
  const batchVsMove = asNum(r.diff_batch_vs_movement_unit);
  const receiptVsMove = asNum(r.diff_receipt_vs_movement_unit);
  const remaining = asNum(r.remaining_qty);
  const absMaxUnitGap = Math.max(Math.abs(batchVsMove), Math.abs(receiptVsMove));
  return {
    ...r,
    abs_max_unit_gap: absMaxUnitGap,
    has_significant_gap: absMaxUnitGap > Math.max(0.01, Math.abs(asNum(r.movement_unit_cost)) * 0.05),
    has_remaining_stock: remaining > 0,
  };
});

const summary = {
  scannedAt: new Date().toISOString(),
  totalBatchRows: rows.length,
  significantGapRows: rows.filter((x) => x.has_significant_gap).length,
  significantGapRowsWithRemaining: rows.filter((x) => x.has_significant_gap && x.has_remaining_stock).length,
};

const report = { summary, rows };

const ts = new Date().toISOString().replace(/[:.]/g, '-');
const jsonPath = path.join(process.cwd(), 'backups', `batch_item_diff_report_${ts}.json`);
const csvPath = path.join(process.cwd(), 'backups', `batch_item_diff_report_${ts}.csv`);
const csvSignificantPath = path.join(process.cwd(), 'backups', `batch_item_diff_report_significant_${ts}.csv`);

fs.writeFileSync(jsonPath, JSON.stringify(report, null, 2), 'utf8');

const headers = [
  'po_number',
  'po_reference',
  'receipt_id',
  'batch_id',
  'item_id',
  'warehouse_id',
  'batch_status',
  'qc_status',
  'quantity_received',
  'quantity_consumed',
  'quantity_transferred',
  'remaining_qty',
  'batch_unit_cost',
  'receipt_unit_cost',
  'movement_unit_cost',
  'diff_batch_vs_receipt_unit',
  'diff_batch_vs_movement_unit',
  'diff_receipt_vs_movement_unit',
  'diff_batch_vs_movement_total_on_remaining',
  'abs_max_unit_gap',
  'has_significant_gap',
  'has_remaining_stock',
  'batch_created_at',
];

const csv = [
  headers.join(','),
  ...rows.map((r) => [
    q(r.po_number),
    q(r.po_reference),
    q(r.receipt_id),
    q(r.batch_id),
    q(r.item_id),
    q(r.warehouse_id),
    q(r.batch_status),
    q(r.qc_status),
    q(r.quantity_received),
    q(r.quantity_consumed),
    q(r.quantity_transferred),
    q(r.remaining_qty),
    q(r.batch_unit_cost),
    q(r.receipt_unit_cost),
    q(r.movement_unit_cost),
    q(r.diff_batch_vs_receipt_unit),
    q(r.diff_batch_vs_movement_unit),
    q(r.diff_receipt_vs_movement_unit),
    q(r.diff_batch_vs_movement_total_on_remaining),
    q(r.abs_max_unit_gap),
    q(r.has_significant_gap),
    q(r.has_remaining_stock),
    q(r.batch_created_at),
  ].join(',')),
].join('\n');

fs.writeFileSync(csvPath, csv, 'utf8');

const significantRows = rows.filter((r) => r.has_significant_gap);
const csvSignificant = [
  headers.join(','),
  ...significantRows.map((r) => [
    q(r.po_number),
    q(r.po_reference),
    q(r.receipt_id),
    q(r.batch_id),
    q(r.item_id),
    q(r.warehouse_id),
    q(r.batch_status),
    q(r.qc_status),
    q(r.quantity_received),
    q(r.quantity_consumed),
    q(r.quantity_transferred),
    q(r.remaining_qty),
    q(r.batch_unit_cost),
    q(r.receipt_unit_cost),
    q(r.movement_unit_cost),
    q(r.diff_batch_vs_receipt_unit),
    q(r.diff_batch_vs_movement_unit),
    q(r.diff_receipt_vs_movement_unit),
    q(r.diff_batch_vs_movement_total_on_remaining),
    q(r.abs_max_unit_gap),
    q(r.has_significant_gap),
    q(r.has_remaining_stock),
    q(r.batch_created_at),
  ].join(',')),
].join('\n');

fs.writeFileSync(csvSignificantPath, csvSignificant, 'utf8');

console.log(JSON.stringify({ jsonPath, csvPath, csvSignificantPath, summary }, null, 2));
