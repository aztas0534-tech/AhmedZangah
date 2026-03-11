import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const loadEnv = (filePath) => {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    for (const line of raw.split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith('#')) continue;
      const i = t.indexOf('=');
      if (i <= 0) continue;
      const k = t.slice(0, i).trim();
      let v = t.slice(i + 1).trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      if (!process.env[k]) process.env[k] = v;
    }
  } catch {}
};

loadEnv(path.join(process.cwd(), '.env.production'));
loadEnv(path.join(process.cwd(), '.env.local'));

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const requested = String(process.env.MIGRATION_VERSIONS || '').split(',').map((x) => x.trim()).filter(Boolean);
if (!requested.length) throw new Error('MIGRATION_VERSIONS is required, e.g. 20260311203000,20260311211000');

const migrationsDir = path.resolve('supabase/migrations');
const allFiles = fs.readdirSync(migrationsDir).filter((f) => /^\d+.*\.sql$/i.test(f));

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const result = { requested, applied: [], skipped: [] };

await client.connect();
try {
  for (const version of requested) {
    const file = allFiles.find((f) => f.startsWith(version + '_'));
    if (!file) throw new Error(`Migration file not found for version ${version}`);

    const already = await client.query(
      'select exists(select 1 from supabase_migrations.schema_migrations where version = $1) as ok',
      [version]
    );
    if (already.rows?.[0]?.ok) {
      result.skipped.push({ version, file, reason: 'already_applied' });
      continue;
    }

    let sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    if (sql.charCodeAt(0) === 0xfeff) sql = sql.slice(1);

    await client.query('begin');
    try {
      await client.query(sql);
      await client.query(
        `insert into supabase_migrations.schema_migrations(version, name)
         values ($1, $2)
         on conflict (version) do nothing`,
        [version, file]
      );
      await client.query('commit');
      result.applied.push({ version, file });
    } catch (e) {
      await client.query('rollback');
      throw e;
    }
  }
} finally {
  await client.end();
}

console.log(JSON.stringify(result, null, 2));
