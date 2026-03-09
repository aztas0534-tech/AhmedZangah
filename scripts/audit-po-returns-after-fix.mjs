import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const poNumbers = ['PO-MAIN-2026-000002', 'PO-MAIN-2026-000003', 'PO-MAIN-2026-000004'];
const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const n = (v) => Number(v || 0) || 0;
const by = (arr, keyFn) => arr.reduce((m, x) => {
  const k = keyFn(x);
  if (!k) return m;
  m[k] = m[k] || [];
  m[k].push(x);
  return m;
}, {});

await client.connect();
const out = { generated_at: new Date().toISOString(), po_numbers: poNumbers, rows: [], summary: {} };
try {
  const poRes = await client.query(`
    select id::text as id, po_number, warehouse_id::text as warehouse_id, status, purchase_date, currency
    from public.purchase_orders
    where po_number = any($1::text[])
    order by po_number asc
  `, [poNumbers]);
  const pos = poRes.rows || [];
  const poIds = pos.map((x) => x.id);

  const receipts = poIds.length ? (await client.query(`
    select pr.purchase_order_id::text as po_id, pri.item_id::text as item_id, sum(coalesce(pri.quantity,0))::numeric as qty
    from public.purchase_receipts pr
    join public.purchase_receipt_items pri on pri.receipt_id = pr.id
    where pr.purchase_order_id = any($1::uuid[])
    group by pr.purchase_order_id::text, pri.item_id::text
  `, [poIds])).rows : [];

  const returns = poIds.length ? (await client.query(`
    select pr.purchase_order_id::text as po_id, pri.item_id::text as item_id, sum(coalesce(pri.quantity,0))::numeric as qty
    from public.purchase_returns pr
    join public.purchase_return_items pri on pri.return_id = pr.id
    where pr.purchase_order_id = any($1::uuid[])
    group by pr.purchase_order_id::text, pri.item_id::text
  `, [poIds])).rows : [];

  const movementsIn = poIds.length ? (await client.query(`
    select pr.purchase_order_id::text as po_id, im.item_id::text as item_id, sum(coalesce(im.quantity,0))::numeric as qty
    from public.inventory_movements im
    join public.purchase_receipts pr on pr.id::text = im.reference_id
    where im.reference_table = 'purchase_receipts'
      and im.movement_type = 'purchase_in'
      and pr.purchase_order_id = any($1::uuid[])
    group by pr.purchase_order_id::text, im.item_id::text
  `, [poIds])).rows : [];

  const movementsRet = poIds.length ? (await client.query(`
    select pr.purchase_order_id::text as po_id, im.item_id::text as item_id, sum(coalesce(im.quantity,0))::numeric as qty
    from public.inventory_movements im
    join public.purchase_returns pr on pr.id::text = im.reference_id
    where im.reference_table = 'purchase_returns'
      and im.movement_type = 'return_out'
      and pr.purchase_order_id = any($1::uuid[])
    group by pr.purchase_order_id::text, im.item_id::text
  `, [poIds])).rows : [];

  const items = poIds.length ? (await client.query(`
    select pi.purchase_order_id::text as po_id, pi.item_id::text as item_id
    from public.purchase_items pi
    where pi.purchase_order_id = any($1::uuid[])
  `, [poIds])).rows : [];

  const itemIds = Array.from(new Set(items.map((x) => x.item_id)));
  const whIds = Array.from(new Set(pos.map((x) => x.warehouse_id).filter(Boolean)));
  const stocks = (itemIds.length && whIds.length) ? (await client.query(`
    select sm.item_id::text as item_id, sm.warehouse_id::text as warehouse_id, coalesce(sm.available_quantity,0)::numeric as available_quantity
    from public.stock_management sm
    where sm.item_id::text = any($1::text[])
      and sm.warehouse_id = any($2::uuid[])
  `, [itemIds, whIds])).rows : [];

  const recByPoItem = new Map(receipts.map((r) => [`${r.po_id}|${r.item_id}`, n(r.qty)]));
  const retByPoItem = new Map(returns.map((r) => [`${r.po_id}|${r.item_id}`, n(r.qty)]));
  const inByPoItem = new Map(movementsIn.map((r) => [`${r.po_id}|${r.item_id}`, n(r.qty)]));
  const outByPoItem = new Map(movementsRet.map((r) => [`${r.po_id}|${r.item_id}`, n(r.qty)]));
  const stockByItemWh = new Map(stocks.map((s) => [`${s.item_id}|${s.warehouse_id}`, n(s.available_quantity)]));
  const itemRowsByPo = by(items, (x) => x.po_id);

  for (const po of pos) {
    const rows = (itemRowsByPo[po.id] || []).map((it) => {
      const k = `${po.id}|${it.item_id}`;
      const received = recByPoItem.get(k) || 0;
      const returned = retByPoItem.get(k) || 0;
      const purchaseIn = inByPoItem.get(k) || 0;
      const returnOut = outByPoItem.get(k) || 0;
      const net = received - returned;
      const stockNow = stockByItemWh.get(`${it.item_id}|${po.warehouse_id}`) ?? null;
      return {
        item_id: it.item_id,
        received_qty: received,
        returned_qty: returned,
        net_qty: net,
        purchase_in_qty: purchaseIn,
        return_out_qty: returnOut,
        stock_now_in_po_warehouse: stockNow,
        full_return_for_item: received > 0 && returned + 1e-9 >= received,
        movement_match: Math.abs(received - purchaseIn) <= 1e-9 && Math.abs(returned - returnOut) <= 1e-9,
      };
    });
    const totalReceived = rows.reduce((s, r) => s + n(r.received_qty), 0);
    const totalReturned = rows.reduce((s, r) => s + n(r.returned_qty), 0);
    out.rows.push({
      po_number: po.po_number,
      po_id: po.id,
      warehouse_id: po.warehouse_id,
      status: po.status,
      total_received_qty: totalReceived,
      total_returned_qty: totalReturned,
      full_return_for_order: totalReceived > 0 && (totalReturned + 1e-9) >= totalReceived,
      items: rows,
    });
  }

  out.summary = {
    orders_count: out.rows.length,
    full_return_orders: out.rows.filter((x) => x.full_return_for_order).map((x) => x.po_number),
    partial_return_orders: out.rows.filter((x) => !x.full_return_for_order && x.total_returned_qty > 0).map((x) => x.po_number),
  };
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'backups', 'po_returns_postfix_audit.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
