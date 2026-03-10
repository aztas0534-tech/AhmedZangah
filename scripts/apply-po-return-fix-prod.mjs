import fs from 'node:fs';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const version = '20260310180000';
const file = '20260310180000_complete_purchase_returns_uom_fx_party.sql';
const sql = fs.readFileSync(`supabase/migrations/${file}`, 'utf8');

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
  await client.query(
    `insert into supabase_migrations.schema_migrations(version, name)
     values ($1, $2)
     on conflict (version) do nothing`,
    [version, file]
  );
  const verify = await client.query(`
    select position(
      'recompute_purchase_return_item_costs'
      in pg_get_functiondef('public.create_purchase_return_v2(uuid,jsonb,text,timestamptz,text)'::regprocedure)
    ) > 0 as has_recompute,
    exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'journal_entries'
        and column_name = 'currency_code'
    ) as has_je_currency,
    exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'journal_lines'
        and column_name = 'party_id'
    ) as has_jl_party
  `);
  console.log(JSON.stringify(verify.rows?.[0] || {}, null, 2));
} finally {
  await client.end();
}
