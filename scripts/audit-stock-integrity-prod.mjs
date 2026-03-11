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

const summary = (await client.query(
  `
  with active_batches as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) as qty,
      case
        when sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) > 0
        then
          sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) * coalesce(b.unit_cost,0))
          / sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0))
        else 0
      end as weighted_cost
    from public.batches b
    where coalesce(b.status,'active')='active'
    group by b.item_id::text, b.warehouse_id
  ),
  joined as (
    select
      coalesce(sm.item_id::text, ab.item_id) as item_id,
      coalesce(sm.warehouse_id, ab.warehouse_id) as warehouse_id,
      coalesce(sm.available_quantity,0) as sm_qty,
      coalesce(sm.avg_cost,0) as sm_avg_cost,
      coalesce(ab.qty,0) as batch_qty,
      coalesce(ab.weighted_cost,0) as batch_weighted_cost
    from public.stock_management sm
    full outer join active_batches ab
      on ab.item_id = sm.item_id::text
     and ab.warehouse_id = sm.warehouse_id
  )
  select
    (select count(*) from public.batches b
      where coalesce(b.status,'active')='active'
        and greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) < 0) as active_batches_negative_remaining,
    (select count(*) from public.stock_management sm where coalesce(sm.available_quantity,0) < 0) as stock_negative_qty_rows,
    (select count(*) from joined j where abs(j.sm_qty - j.batch_qty) > 0.000001) as qty_mismatch_rows,
    (select count(*) from joined j where abs(j.sm_avg_cost - j.batch_weighted_cost) > 0.0001 and j.batch_qty > 0.000001) as avg_cost_mismatch_rows,
    (select count(*) from joined j) as joined_rows
  `
)).rows[0];

const examples = (await client.query(
  `
  with active_batches as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) as qty,
      case
        when sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)) > 0
        then
          sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) * coalesce(b.unit_cost,0))
          / sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0))
        else 0
      end as weighted_cost
    from public.batches b
    where coalesce(b.status,'active')='active'
    group by b.item_id::text, b.warehouse_id
  ),
  joined as (
    select
      coalesce(sm.item_id::text, ab.item_id) as item_id,
      coalesce(sm.warehouse_id, ab.warehouse_id) as warehouse_id,
      coalesce(sm.available_quantity,0) as sm_qty,
      coalesce(sm.avg_cost,0) as sm_avg_cost,
      coalesce(ab.qty,0) as batch_qty,
      coalesce(ab.weighted_cost,0) as batch_weighted_cost
    from public.stock_management sm
    full outer join active_batches ab
      on ab.item_id = sm.item_id::text
     and ab.warehouse_id = sm.warehouse_id
  )
  select *
  from joined j
  where abs(j.sm_qty - j.batch_qty) > 0.000001
     or (abs(j.sm_avg_cost - j.batch_weighted_cost) > 0.0001 and j.batch_qty > 0.000001)
  order by greatest(abs(j.sm_qty-j.batch_qty), abs(j.sm_avg_cost-j.batch_weighted_cost)) desc
  limit 20
  `
)).rows;

await client.end();

const out = { scannedAt: new Date().toISOString(), summary, examples };
const outPath = path.join(process.cwd(), 'backups', `stock_integrity_audit_${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
