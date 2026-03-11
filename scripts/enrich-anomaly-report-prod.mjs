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

const reportPath = String(process.env.REPORT_PATH || '').trim();
if (!reportPath) throw new Error('REPORT_PATH is required');

const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const receiptIds = new Set();
const itemIds = new Set();
for (const r of report.duplicateActiveGroups || []) {
  receiptIds.add(String(r.receipt_id));
  itemIds.add(String(r.item_id));
}
for (const r of report.suspiciousCostMismatches || []) {
  receiptIds.add(String(r.receipt_id));
  itemIds.add(String(r.item_id));
}

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

await client.connect();

const receiptMeta = receiptIds.size
  ? await client.query(
    `select pr.id as receipt_id, pr.purchase_order_id, po.po_number, po.reference_number, pr.received_at
     from public.purchase_receipts pr
     left join public.purchase_orders po on po.id = pr.purchase_order_id
     where pr.id = any($1::uuid[])`,
    [[...receiptIds]]
  )
  : { rows: [] };

const itemMeta = itemIds.size
  ? await client.query(
    `select mi.id::text as item_id, mi.id::text as item_name
     from public.menu_items mi
     where mi.id::text = any($1::text[])`,
    [[...itemIds]]
  )
  : { rows: [] };

await client.end();

const receiptMap = new Map(receiptMeta.rows.map((r) => [String(r.receipt_id), r]));
const itemMap = new Map(itemMeta.rows.map((r) => [String(r.item_id), String(r.item_name)]));

const enriched = {
  summary: report.summary,
  duplicateActiveGroups: (report.duplicateActiveGroups || []).map((r) => ({
    ...r,
    po_number: receiptMap.get(String(r.receipt_id))?.po_number || null,
    po_reference: receiptMap.get(String(r.receipt_id))?.reference_number || null,
    item_name: itemMap.get(String(r.item_id)) || null,
  })),
  suspiciousCostMismatches: (report.suspiciousCostMismatches || []).map((r) => ({
    ...r,
    po_number: receiptMap.get(String(r.receipt_id))?.po_number || null,
    po_reference: receiptMap.get(String(r.receipt_id))?.reference_number || null,
    item_name: itemMap.get(String(r.item_id)) || null,
  })),
};

const outPath = path.join(process.cwd(), 'backups', `enriched_${path.basename(reportPath)}`);
fs.writeFileSync(outPath, JSON.stringify(enriched, null, 2), 'utf8');
console.log(outPath);
