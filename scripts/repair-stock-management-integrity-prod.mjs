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

const apply = String(process.env.APPLY || '').trim() === '1';

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password: String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || ''),
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const getSummary = async () => (await client.query(
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
      coalesce(ab.weighted_cost,0) as batch_weighted_cost,
      sm.item_id is null as missing_stock_row
    from public.stock_management sm
    full outer join active_batches ab
      on ab.item_id = sm.item_id::text
     and ab.warehouse_id = sm.warehouse_id
  )
  select
    (select count(*) from joined j where abs(j.sm_qty - j.batch_qty) > 0.000001) as qty_mismatch_rows,
    (select count(*) from joined j where abs(j.sm_avg_cost - j.batch_weighted_cost) > 0.0001 and j.batch_qty > 0.000001) as avg_cost_mismatch_rows,
    (select count(*) from joined j where j.missing_stock_row = true and j.batch_qty > 0.000001) as missing_stock_rows_with_batches
  `
)).rows[0];

await client.connect();
const before = await getSummary();

let updatedRows = 0;
if (apply) {
  try {
    await client.query('begin');
    const r1 = await client.query(
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
      )
      update public.stock_management sm
      set available_quantity = ab.qty,
          avg_cost = ab.weighted_cost,
          updated_at = now(),
          last_updated = now()
      from active_batches ab
      where sm.item_id::text = ab.item_id
        and sm.warehouse_id = ab.warehouse_id
        and (
          abs(coalesce(sm.available_quantity,0) - coalesce(ab.qty,0)) > 0.000001
          or abs(coalesce(sm.avg_cost,0) - coalesce(ab.weighted_cost,0)) > 0.0001
        )
      `
    );
    updatedRows += r1.rowCount || 0;
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }
}

const after = await getSummary();
await client.end();

const out = { apply, updatedRows, before, after };
const outPath = path.join(process.cwd(), 'backups', `repair_stock_management_integrity_${apply ? 'applied' : 'dry'}_${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
