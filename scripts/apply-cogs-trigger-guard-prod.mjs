import fs from 'node:fs';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const sql = fs.readFileSync('supabase/migrations/20260310120000_guard_order_item_cogs_from_sale_out_trigger.sql', 'utf8');

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

await client.connect();
try {
  await client.query(sql);
  const verify = await client.query(`
    select
      to_regprocedure('public.sync_order_item_cogs_from_sale_out(uuid)') is not null as has_sync_fn,
      exists (
        select 1
        from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = 'inventory_movements'
          and t.tgname = 'trg_sync_order_item_cogs_from_sale_out'
          and not t.tgisinternal
      ) as has_trigger
  `);
  console.log(JSON.stringify(verify.rows?.[0] || {}, null, 2));
} finally {
  await client.end();
}
