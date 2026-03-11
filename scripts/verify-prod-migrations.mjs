import fs from 'fs';
import path from 'path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) {
  console.error('Missing DBPW or SUPABASE_DB_PASSWORD');
  process.exit(1);
}

const run = async () => {
  const migrationsDir = path.resolve('supabase/migrations');
  const local = fs.readdirSync(migrationsDir)
    .filter((f) => /^\d+.*\.sql$/i.test(f))
    .map((f) => ({ version: f.split('_')[0], file: f }));

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
    const { rows } = await client.query('select version::text as version, name from supabase_migrations.schema_migrations');
    const remote = rows.map((r) => ({ version: String(r.version), name: String(r.name || '') }));
    const remoteSet = new Set(remote.map((r) => r.version));
    const localSet = new Set(local.map((r) => r.version));
    const missingOnRemote = local.filter((m) => !remoteSet.has(m.version)).sort((a, b) => a.version.localeCompare(b.version));
    const extraOnRemote = remote.filter((m) => !localSet.has(m.version)).sort((a, b) => a.version.localeCompare(b.version));
    const latestLocal = local.map((x) => x.version).sort().slice(-1)[0] || '';
    const latestRemote = remote.map((x) => x.version).sort().slice(-1)[0] || '';

    const checks = await client.query(`
      select
        exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='resolve_payment_destination_account') as has_resolver,
        exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='payments' and t.tgname='trg_validate_payment_destination_account' and not t.tgisinternal) as has_trigger,
        exists(select 1 from supabase_migrations.schema_migrations where version='20260308012000') as has_hardening_migration,
        position('resolve_payment_destination_account(v_method' in pg_get_functiondef('public.record_order_payment_v2(uuid,numeric,text,timestamptz,text,text,jsonb)'::regprocedure)) > 0 as v2_uses_resolver,
        position('jsonb_set(v_data, ''{destinationAccountId}''' in pg_get_functiondef('public.record_order_payment_v2(uuid,numeric,text,timestamptz,text,text,jsonb)'::regprocedure)) > 0 as v2_normalizes_destination,
        position('v_pay.data->>''destinationAccountId''' in pg_get_functiondef('public.post_payment(uuid)'::regprocedure)) > 0 as post_payment_reads_destination
    `);

    console.log(JSON.stringify({
      local_count: local.length,
      remote_count: remote.length,
      latest_local: latestLocal,
      latest_remote: latestRemote,
      missing_on_remote_count: missingOnRemote.length,
      missing_on_remote: missingOnRemote.slice(0, 50),
      extra_on_remote_count: extraOnRemote.length,
      extra_on_remote: extraOnRemote.slice(0, 50),
      checks: checks.rows[0],
    }, null, 2));
  } finally {
    await client.end();
  }
};

run().catch((e) => {
  console.error('verify_prod_migrations_failed:', e?.message || e);
  process.exit(1);
});
