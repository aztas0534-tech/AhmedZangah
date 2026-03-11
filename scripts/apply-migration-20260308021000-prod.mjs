import fs from 'fs';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) {
  console.error('Missing DBPW or SUPABASE_DB_PASSWORD');
  process.exit(1);
}

const sql = fs.readFileSync('supabase/migrations/20260308021000_skip_customer_credit_when_party_credit_used.sql', 'utf8');

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const run = async () => {
  await client.connect();
  try {
    await client.query('begin');
    await client.query(sql);
    await client.query(`
      insert into supabase_migrations.schema_migrations(version, name)
      values ('20260308021000', 'skip_customer_credit_when_party_credit_used')
      on conflict (version) do nothing
    `);
    await client.query('commit');
    const { rows } = await client.query(`
      select
        exists(select 1 from supabase_migrations.schema_migrations where version='20260308021000') as migration_registered,
        position('and not (v_is_credit and v_party_id is not null)' in pg_get_functiondef('public.confirm_order_delivery(uuid,jsonb,jsonb,uuid)'::regprocedure)) > 0 as guard_present
    `);
    console.log(JSON.stringify(rows[0] || {}, null, 2));
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    await client.end();
  }
};

run().catch((e) => {
  console.error('apply_migration_20260308021000_failed:', e?.message || e);
  process.exit(1);
});
