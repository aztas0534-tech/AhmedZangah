import fs from 'fs';
import { Client } from 'pg';

const sqlPath = 'supabase/migrations/20260307235900_fix_party_credit_limit_base_fallback_fx.sql';
const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();

if (!password) {
  console.error('Missing DBPW or SUPABASE_DB_PASSWORD');
  process.exit(1);
}

const run = async () => {
  const sql = fs.readFileSync(sqlPath, 'utf8');
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
    await client.query('begin');
    await client.query(sql);
    await client.query('commit');

    const verify = await client.query(
      "select pg_get_functiondef('public.check_party_credit_limit(uuid,numeric,text)'::regprocedure) as def"
    );
    const body = String(verify.rows?.[0]?.def || '');
    const ok = body.includes('v_amount_base := v_amount_in_currency * v_fx');
    console.log(JSON.stringify({
      applied: true,
      verify_fx_fallback: ok,
      migration: sqlPath,
    }, null, 2));
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    await client.end();
  }
};

run().catch((e) => {
  console.error('push_credit_limit_fix_failed:', e?.message || e);
  process.exit(1);
});
