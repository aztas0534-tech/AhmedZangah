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

const poRef = String(process.env.PO_REF || 'PO-MAIN-2026-000037').trim();
const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

await client.connect();

const one = async (sql, params = []) => (await client.query(sql, params)).rows;

const poRows = await one(
  `select id, po_number, reference_number, status, currency, fx_rate, total_amount, base_total, warehouse_id, supplier_id, created_at, updated_at
   from public.purchase_orders
   where po_number = $1 or reference_number = $1
   order by created_at desc`,
  [poRef]
);
if (poRows.length === 0) {
  console.log(JSON.stringify({ poRef, found: false }, null, 2));
  await client.end();
  process.exit(0);
}
const po = poRows[0];

const receipts = await one(
  `select id, received_at, import_shipment_id, warehouse_id, posting_status, posting_error, created_at
   from public.purchase_receipts
   where purchase_order_id = $1
   order by created_at asc`,
  [po.id]
);
const receiptIds = receipts.map((r) => r.id);

const receiptItems = receiptIds.length
  ? await one(
    `select receipt_id, item_id, quantity, unit_cost, transport_cost, supply_tax_cost, total_cost, pre_close_unit_cost, created_at
     from public.purchase_receipt_items
     where receipt_id = any($1::uuid[])
     order by receipt_id, item_id`,
    [receiptIds]
  )
  : [];

const shipmentIds = [...new Set(receipts.map((r) => r.import_shipment_id).filter(Boolean))];
const shipmentLinks = await one(
  `select shipment_id, purchase_order_id, created_at
   from public.import_shipment_purchase_orders
   where purchase_order_id = $1
   order by created_at asc`,
  [po.id]
);
for (const l of shipmentLinks) {
  if (l.shipment_id && !shipmentIds.includes(l.shipment_id)) shipmentIds.push(l.shipment_id);
}
const shipments = shipmentIds.length
  ? await one(
    `select id, reference_number, status, destination_warehouse_id, actual_arrival_date, updated_at
     from public.import_shipments
     where id = any($1::uuid[])`,
    [shipmentIds]
  )
  : [];

const shipmentItems = shipmentIds.length
  ? await one(
    `select shipment_id, item_id, quantity, unit_price_fob, landing_cost_per_unit, currency, updated_at
     from public.import_shipments_items
     where shipment_id = any($1::uuid[])
     order by shipment_id, item_id`,
    [shipmentIds]
  )
  : [];

const expenses = shipmentIds.length
  ? await one(
    `select shipment_id, description, amount, currency, exchange_rate, expense_type, created_at
     from public.import_expenses
     where shipment_id = any($1::uuid[])
     order by created_at asc`,
    [shipmentIds]
  )
  : [];

const items = await one(
  `select item_id, quantity, qty_base, received_quantity, uom_id, unit_cost, unit_cost_base, unit_cost_foreign
   from public.purchase_items
   where purchase_order_id = $1`,
  [po.id]
);
const itemIds = [...new Set(items.map((x) => x.item_id))];

const batches = receiptIds.length
  ? await one(
    `select id, item_id, receipt_id, warehouse_id, qc_status, status, quantity_received, quantity_consumed, quantity_transferred, expiry_date, pre_close_unit_cost, unit_cost, created_at, updated_at
     from public.batches
     where receipt_id = any($1::uuid[])
     order by created_at asc`,
    [receiptIds]
  )
  : [];

const batchIds = batches.map((b) => b.id);
const qcChecks = batchIds.length
  ? await one(
    `select batch_id, check_type, result, checked_at, checked_by
     from public.qc_checks
     where batch_id = any($1::uuid[])
     order by checked_at asc`,
    [batchIds]
  )
  : [];

const stock = itemIds.length
  ? await one(
    `select item_id, warehouse_id, available_quantity, qc_hold_quantity, reserved_quantity, avg_cost, last_batch_id, updated_at
     from public.stock_management
     where item_id = any($1::text[]) and warehouse_id = $2`,
    [itemIds, po.warehouse_id]
  )
  : [];

const movements = receiptIds.length
  ? await one(
    `select id, item_id, movement_type, quantity, unit_cost, reference_table, reference_id, batch_id, warehouse_id, occurred_at
     from public.inventory_movements
     where reference_table='purchase_receipts' and reference_id = any($1::text[])
     order by occurred_at asc`,
    [receiptIds.map(String)]
  )
  : [];

await client.end();

const out = {
  poRef,
  found: true,
  purchase_order: po,
  purchase_items: items,
  receipts,
  receipt_items: receiptItems,
  import_shipment_links: shipmentLinks,
  import_shipments: shipments,
  import_shipment_items: shipmentItems,
  import_expenses: expenses,
  batches,
  qc_checks: qcChecks,
  stock_management: stock,
  inventory_movements: movements,
};

const outPath = path.join(process.cwd(), 'backups', `deep_po_trace_${poRef.replace(/[^a-zA-Z0-9_-]/g, '_')}.json`);
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
