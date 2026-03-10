import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const versions = [
  '20260310000000',
  '20260310020000',
  '20260310101000',
  '20260310120000',
  '20260310133000',
];

const migrationsDir = path.resolve('supabase/migrations');

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
  for (const version of versions) {
    const file = fs.readdirSync(migrationsDir).find((f) => f.startsWith(version + '_') && f.endsWith('.sql'));
    if (!file) throw new Error(`Migration file not found for version ${version}`);

    const applied = await client.query(
      'select exists(select 1 from supabase_migrations.schema_migrations where version = $1) as ok',
      [version]
    );
    if (applied.rows?.[0]?.ok) {
      console.log(`Skipping already applied: ${file}`);
      continue;
    }

    let sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    if (sql.charCodeAt(0) === 0xfeff) sql = sql.slice(1);

    console.log(`Applying ${file} ...`);
    await client.query(sql);
    await client.query(
      `insert into supabase_migrations.schema_migrations(version, name)
       values ($1, $2)
       on conflict (version) do nothing`,
      [version, file]
    );
    console.log(`Applied ${file}`);
  }
} finally {
  await client.end();
}

