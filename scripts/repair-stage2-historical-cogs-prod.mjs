import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const num = (v) => Number(v || 0);
const pingPath = path.join(process.cwd(), 'stage2_repair_ping.txt');
const outPath = path.join(process.cwd(), 'product_anomalies_stage2_repair.json');
const errPath = path.join(process.cwd(), 'product_anomalies_stage2_repair_error.json');

const out = { generated_at: new Date().toISOString(), items: [], dry_run_results: [], apply_results: [] };
const ping = (msg) => fs.appendFileSync(pingPath, `${new Date().toISOString()} ${msg}\n`, 'utf8');
fs.writeFileSync(pingPath, '', 'utf8');

try {
  ping('start');
  await client.connect();
  ping('connected');

  const actor = (await client.query(`
    select auth_user_id
    from public.admin_users
    where is_active = true
    order by (case when role='owner' then 1 else 0 end) desc, created_at asc nulls last
    limit 1
  `)).rows[0];
  if (!actor?.auth_user_id) throw new Error('No active admin user');
  ping('actor_ready');

  await client.query(
    `select
      set_config('request.jwt.claim.sub', $1::text, false),
      set_config('request.jwt.claim.role', 'authenticated', false),
      set_config('request.jwt.claims', json_build_object('sub',$1::text,'role','authenticated')::text, false)`,
    [actor.auth_user_id]
  );
  ping('session_ready');

  const rows = (await client.query(
    `select item_id,total_sales,total_cost,quantity_sold
     from public.get_product_sales_report_v9($1::timestamptz,$2::timestamptz,$3::uuid,$4::boolean)`,
    ['1970-01-01T00:00:00.000Z', new Date().toISOString(), null, false]
  )).rows;
  ping(`rows=${rows.length}`);

  out.items = rows
    .filter((r) => {
      const sales = num(r.total_sales);
      const cost = num(r.total_cost);
      const qty = num(r.quantity_sold);
      return (sales > 0 && cost === 0) || (cost > sales + 0.01) || (sales > 0 && qty <= 0) || (sales > 0 && (cost / sales) > 1.5);
    })
    .map((r) => String(r.item_id));
  ping(`anomalous_items=${out.items.length}`);

  for (const itemId of out.items) {
    const d = (await client.query(
      `select public.repair_historical_sale_cogs($1::text,$2::uuid,$3::boolean) as r`,
      [itemId, null, true]
    )).rows[0]?.r || {};
    out.dry_run_results.push({ item_id: itemId, result: d });
  }
  ping('dry_run_done');

  for (const itemId of out.items) {
    const a = (await client.query(
      `select public.repair_historical_sale_cogs($1::text,$2::uuid,$3::boolean) as r`,
      [itemId, null, false]
    )).rows[0]?.r || {};
    out.apply_results.push({ item_id: itemId, result: a });
  }
  ping('apply_done');

  fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
  ping('output_written');
  console.log(outPath);
} catch (e) {
  fs.writeFileSync(errPath, JSON.stringify({ message: e?.message, stack: e?.stack, code: e?.code, detail: e?.detail }, null, 2), 'utf8');
  ping(`error=${e?.message || e}`);
  throw e;
} finally {
  try {
    await client.end();
  } catch {}
  ping('end');
}
