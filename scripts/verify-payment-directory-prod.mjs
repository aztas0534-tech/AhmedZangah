import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) {
  console.error('Missing DBPW or SUPABASE_DB_PASSWORD');
  process.exit(1);
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
    const { rows } = await client.query(`
      select
        exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='trg_validate_payment_directory_destination_account') as has_fn,
        exists(select 1 from pg_trigger t join pg_class c2 on c2.oid=t.tgrelid join pg_namespace n on n.oid=c2.relnamespace where n.nspname='public' and c2.relname='banks' and t.tgname='trg_validate_payment_directory_destination_account' and not t.tgisinternal) as banks_trigger,
        exists(select 1 from pg_trigger t join pg_class c2 on c2.oid=t.tgrelid join pg_namespace n on n.oid=c2.relnamespace where n.nspname='public' and c2.relname='transfer_recipients' and t.tgname='trg_validate_payment_directory_destination_account' and not t.tgisinternal) as recipients_trigger,
        exists(select 1 from supabase_migrations.schema_migrations where version='20260308014500') as migration_registered
    `);
    const result = rows[0] || {};
    console.log(JSON.stringify({
      ...result,
      ready: Boolean(result.has_fn && result.banks_trigger && result.recipients_trigger && result.migration_registered),
    }, null, 2));
  } finally {
    await client.end();
  }
};

run().catch((e) => {
  console.error('verify_payment_directory_prod_failed:', e?.message || e);
  process.exit(1);
});
