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

const names = [
  'receive_purchase_order',
  'receive_purchase_order_partial',
  '_receive_purchase_order_partial_impl',
  'recompute_stock_for_item',
  'qc_inspect_batch',
  'qc_release_batch',
  'trg_close_import_shipment',
  'calculate_shipment_landed_cost',
  'reserve_stock_for_order',
  'release_reserved_stock_for_order',
];

await client.connect();
const out = [];
for (const n of names) {
  const q = await client.query(
    `
    select p.oid::regprocedure::text as signature,
           pg_get_functiondef(p.oid) as def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public' and p.proname = $1
    order by 1
  `,
    [n]
  );
  out.push(`-- ===== ${n} =====`);
  if (q.rows.length === 0) {
    out.push('-- not found');
  } else {
    for (const r of q.rows) {
      out.push(`-- signature: ${r.signature}`);
      out.push(r.def);
      out.push('');
    }
  }
}
await client.end();

const outPath = path.join(process.cwd(), 'backups', 'prod_function_defs.sql');
fs.writeFileSync(outPath, out.join('\n'), 'utf8');
console.log(outPath);
