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

const sourcePath = path.join(process.cwd(), 'supabase', 'migrations', '20260217150000_fix_product_report_cogs_fallback.sql');
let sql = fs.readFileSync(sourcePath, 'utf8');

if (!sql.includes(`cogs_movement as (`)) {
  if (!sql.includes(`  cogs_recorded as (`)) throw new Error('cogs_recorded marker not found in source SQL');
  sql = sql.replace(
    `  cogs_recorded as (`,
    `  cogs_movement as (
    select
      im.item_id::text as item_id_text,
      sum(coalesce(nullif(im.total_cost, 0), im.quantity * coalesce(nullif(im.unit_cost, 0), 0))) as movement_cost
    from public.inventory_movements im
    join sales_orders so on so.id::text = im.reference_id
    where im.reference_table = 'orders'
      and im.movement_type = 'sale_out'
    group by im.item_id::text
  ),
  -- COGS from order_item_cogs (recorded at delivery time)
  cogs_recorded as (`
  );
}

sql = sql.replaceAll(
  `coalesce(
        cr.recorded_cost,
        -- Fallback: estimate COGS from current avg_cost
        coalesce(sa.avg_cost, mi.cost_price, 0) * greatest(coalesce(sl.qty_sold, 0) - coalesce(rs.qty_returned, 0), 0)
      )`,
  `coalesce(
        cm.movement_cost,
        cr.recorded_cost,
        coalesce(sa.avg_cost, mi.cost_price, 0) * greatest(coalesce(sl.qty_sold, 0) - coalesce(rs.qty_returned, 0), 0)
      )`
);

if (!sql.includes(`left join cogs_movement cm on cm.item_id_text = k.item_id_text`)) {
  sql = sql.replace(
    `  left join cogs_recorded cr on cr.item_id_text = k.item_id_text`,
    `  left join cogs_movement cm on cm.item_id_text = k.item_id_text
  left join cogs_recorded cr on cr.item_id_text = k.item_id_text`
  );
}

const out = { deployed_at: new Date().toISOString(), ok: false };

await client.connect();
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
      set_config('request.jwt.claim.sub', $1::text, false),
      set_config('request.jwt.claim.role', 'authenticated', false),
      set_config('request.jwt.claims', json_build_object('sub',$1::text,'role','authenticated')::text, false)`,
    [actor.auth_user_id]
  );

  await client.query(sql);
  out.ok = true;
} catch (e) {
  out.error = { message: e?.message, code: e?.code, detail: e?.detail };
  throw e;
} finally {
  await client.end();
  fs.writeFileSync('deploy_product_report_cogs_alignment_result.json', JSON.stringify(out, null, 2), 'utf8');
}

console.log(path.join(process.cwd(), 'deploy_product_report_cogs_alignment_result.json'));
