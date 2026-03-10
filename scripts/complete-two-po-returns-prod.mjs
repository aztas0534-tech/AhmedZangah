import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const poNumbers = ['PO-MAIN-2026-000002', 'PO-MAIN-2026-000003'];

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const n = (v) => Number(v || 0) || 0;

await client.connect();
const out = { generated_at: new Date().toISOString(), po_numbers: poNumbers, plans: [], created_returns: [], shortages: [] };
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
      set_config('request.jwt.claims',json_build_object('sub',$1::text,'role','authenticated')::text,false)`,
    [actor.auth_user_id]
  );

  const poRows = (await client.query(`
    select id::text as po_id, po_number
    from public.purchase_orders
    where po_number = any($1::text[])
    order by po_number
  `, [poNumbers])).rows;
  const poIds = poRows.map((x) => x.po_id);
  if (!poIds.length) throw new Error('Purchase orders not found');

  const rec = (await client.query(`
    select pr.purchase_order_id::text po_id, pri.item_id::text item_id, sum(coalesce(pri.quantity,0)) qty_received
    from public.purchase_receipts pr
    join public.purchase_receipt_items pri on pri.receipt_id = pr.id
    where pr.purchase_order_id = any($1::uuid[])
    group by pr.purchase_order_id::text, pri.item_id::text
  `, [poIds])).rows;

  const ret = (await client.query(`
    select pr.purchase_order_id::text po_id, pri.item_id::text item_id, sum(coalesce(pri.quantity,0)) qty_returned
    from public.purchase_returns pr
    join public.purchase_return_items pri on pri.return_id = pr.id
    where pr.purchase_order_id = any($1::uuid[])
    group by pr.purchase_order_id::text, pri.item_id::text
  `, [poIds])).rows;

  const batch = (await client.query(`
    select
      pr.purchase_order_id::text po_id,
      b.item_id::text item_id,
      sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) qty_batch_remaining
    from public.batches b
    join public.purchase_receipts pr on pr.id = b.receipt_id
    where pr.purchase_order_id = any($1::uuid[])
    group by pr.purchase_order_id::text, b.item_id::text
  `, [poIds])).rows;

  const retMap = new Map(ret.map((x) => [`${x.po_id}|${x.item_id}`, n(x.qty_returned)]));
  const batchMap = new Map(batch.map((x) => [`${x.po_id}|${x.item_id}`, n(x.qty_batch_remaining)]));

  const planByPo = new Map();
  for (const r of rec) {
    const k = `${r.po_id}|${r.item_id}`;
    const qtyReceived = n(r.qty_received);
    const qtyReturned = retMap.get(k) || 0;
    const qtyRemaining = Math.max(qtyReceived - qtyReturned, 0);
    if (qtyRemaining <= 0) continue;

    const qtyBatchRemaining = batchMap.get(k) || 0;
    const qtyToReturn = Math.max(Math.min(qtyRemaining, qtyBatchRemaining), 0);

    if (!planByPo.has(r.po_id)) planByPo.set(r.po_id, []);
    planByPo.get(r.po_id).push({
      item_id: r.item_id,
      qty_received: qtyReceived,
      qty_returned: qtyReturned,
      qty_remaining: qtyRemaining,
      qty_batch_remaining: qtyBatchRemaining,
      qty_to_return: qtyToReturn,
    });

    if (qtyToReturn + 1e-9 < qtyRemaining) {
      out.shortages.push({
        po_id: r.po_id,
        item_id: r.item_id,
        short_qty: qtyRemaining - qtyToReturn,
      });
    }
  }

  for (const p of poRows) {
    const lines = (planByPo.get(p.po_id) || []).filter((x) => x.qty_to_return > 0);
    out.plans.push({ po_id: p.po_id, po_number: p.po_number, lines });
    if (!lines.length) continue;

    const payload = lines.map((x) => ({ itemId: x.item_id, quantity: x.qty_to_return }));
    const retId = (await client.query(
      `select public.create_purchase_return($1::uuid,$2::jsonb,$3::text,$4::timestamptz) as return_id`,
      [p.po_id, JSON.stringify(payload), 'اكمال مرتجع كامل متبقي لأمر شراء خاطئ (تصحيح محاسبي ومخزني)', new Date().toISOString()]
    )).rows[0]?.return_id;
    out.created_returns.push({ po_id: p.po_id, po_number: p.po_number, return_id: String(retId), items_count: payload.length });
  }
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'complete_two_po_returns_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
