import fs from 'node:fs';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const sql = fs.readFileSync('supabase/migrations/20260310101000_fix_purchase_return_v2_sync_received_before_validate.sql', 'utf8');

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
    select position(
      'reconcile_purchase_order_receipt_status(p_order_id)'
      in pg_get_functiondef('public.create_purchase_return_v2(uuid,jsonb,text,timestamptz,text)'::regprocedure)
    ) > 0 as has_reconcile
  `);
  console.log(JSON.stringify(verify.rows?.[0] || {}, null, 2));
} finally {
  await client.end();
}
