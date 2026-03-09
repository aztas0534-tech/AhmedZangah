import fs from 'node:fs';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const sql = fs.readFileSync('supabase/migrations/20260310133000_align_accountant_dashboard_sales_base_currency.sql', 'utf8');

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
      to_regprocedure('public.get_accountant_dashboard_summary(timestamptz,timestamptz)') is not null as has_rpc,
      position('order_fx_rate(' in pg_get_functiondef('public.get_accountant_dashboard_summary(timestamptz,timestamptz)'::regprocedure)) > 0 as uses_fx_rate,
      position('date_by' in pg_get_functiondef('public.get_accountant_dashboard_summary(timestamptz,timestamptz)'::regprocedure)) > 0 as uses_effective_date
  `);
  console.log(JSON.stringify(verify.rows?.[0] || {}, null, 2));
} finally {
  await client.end();
}
