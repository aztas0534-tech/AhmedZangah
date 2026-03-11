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
const q = await client.query(
  `
  select po.id, po.po_number, po.reference_number, po.created_at,
         pi.item_id, pi.quantity, pi.qty_base, pi.unit_cost
  from public.purchase_orders po
  join public.purchase_items pi on pi.purchase_order_id = po.id
  where (abs(coalesce(pi.unit_cost,0) - 12.14) < 0.001 or abs(coalesce(pi.unit_cost,0) - 19.29) < 0.001)
    and (abs(coalesce(pi.quantity,0) - 550) < 0.001 or abs(coalesce(pi.quantity,0) - 500) < 0.001)
  order by po.created_at desc
  limit 100
  `
);
const q2 = await client.query(
  `
  select isi.shipment_id, ishp.reference_number, ishp.status, isi.item_id, isi.quantity, isi.unit_price_fob, isi.landing_cost_per_unit, isi.updated_at
  from public.import_shipments_items isi
  join public.import_shipments ishp on ishp.id = isi.shipment_id
  where abs(coalesce(isi.landing_cost_per_unit,0) - 13.085484829667351) < 0.00001
     or abs(coalesce(isi.landing_cost_per_unit,0) - 20.792339568721846) < 0.00001
  order by isi.updated_at desc
  limit 100
  `
);
await client.end();
console.log(JSON.stringify({ po_candidates: q.rows, shipment_item_candidates: q2.rows }, null, 2));
