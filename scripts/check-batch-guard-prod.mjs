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

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

await client.connect();
const trigger = await client.query(
  `select tgname, tgenabled
   from pg_trigger
   where tgrelid='public.batches'::regclass
     and tgname='trg_guard_single_active_batch_per_receipt_item'
     and not tgisinternal`
);
const fn = await client.query(
  `select p.oid::regprocedure::text as signature
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and p.proname='trg_guard_single_active_batch_per_receipt_item'`
);
await client.end();

console.log(JSON.stringify({ trigger: trigger.rows, function: fn.rows }, null, 2));
