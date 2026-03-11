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

const migrationPath = String(process.env.MIGRATION_PATH || '').trim();
if (!migrationPath) throw new Error('MIGRATION_PATH is required');
const checkSql = String(process.env.CHECK_SQL || '').trim();

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

await client.connect();
await client.query(fs.readFileSync(migrationPath, 'utf8'));
let checkRows = [];
if (checkSql) {
  checkRows = (await client.query(checkSql)).rows;
}
await client.end();
console.log(JSON.stringify({ applied: migrationPath, checkRows }, null, 2));
