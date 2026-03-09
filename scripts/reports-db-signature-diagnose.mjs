import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) {
  throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');
}

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
    const health = await client.query(`select public.app_schema_healthcheck() as health`);
    const sig = await client.query(`
      select
        p.proname,
        pg_get_function_identity_arguments(p.oid) as identity_args,
        coalesce(p.proargnames, '{}'::text[]) as arg_names,
        pg_get_function_result(p.oid) as return_type
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public'
        and p.proname in (
          'trial_balance',
          'income_statement',
          'balance_sheet',
          'currency_balances',
          'get_daily_sales_stats',
          'get_daily_sales_stats_v2',
          'get_sales_report_summary',
          'get_sales_report_orders',
          'get_product_sales_report_v9'
        )
      order by p.proname, pg_get_function_identity_arguments(p.oid)
    `);
    const probes = await client.query(`
      select
        to_regprocedure('public.trial_balance(date,date,uuid,uuid)') is not null as has_trial_4,
        to_regprocedure('public.trial_balance(date,date,uuid)') is not null as has_trial_3,
        to_regprocedure('public.trial_balance(date,date)') is not null as has_trial_2,
        to_regprocedure('public.get_daily_sales_stats_v2(timestamptz,timestamptz,uuid,boolean,uuid)') is not null as has_daily_v2,
        to_regprocedure('public.get_daily_sales_stats(timestamptz,timestamptz,uuid,boolean)') is not null as has_daily_v1
    `);
    const mig = await client.query(`
      select version::text
      from supabase_migrations.schema_migrations
      where version in ('20260226141000','20260227050000','20260309101000')
      order by version
    `);

    const result = {
      timestamp: new Date().toISOString(),
      health: health.rows?.[0]?.health || null,
      probes: probes.rows?.[0] || {},
      signatures: sig.rows || [],
      migrations_present: mig.rows?.map((r) => r.version) || [],
    };

    const outPath = path.join(process.cwd(), 'backups', 'reports_db_signature_diag.json');
    fs.writeFileSync(outPath, JSON.stringify(result, null, 2), 'utf8');
    console.log(outPath);
  } finally {
    await client.end();
  }
};

run().catch((e) => {
  console.error(e?.message || e);
  process.exit(1);
});
