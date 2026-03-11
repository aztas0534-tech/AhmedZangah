import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const toNum = (v) => Number(v || 0) || 0;

const out = {
  generated_at: new Date().toISOString(),
  anomalies_before_count: 0,
  batches_fixed: [],
  journals_created: [],
  failures: [],
  anomalies_after_count: 0,
};

await client.connect();
try {
  const actor = (await client.query(`
    select auth_user_id
    from public.admin_users
    where is_active = true
    order by (case when role='owner' then 1 else 0 end) desc, created_at asc nulls last
    limit 1
  `)).rows[0];
  if (!actor?.auth_user_id) throw new Error('No active admin user');
  await client.query(
    `select
      set_config('request.jwt.claim.sub',$1::text,false),
      set_config('request.jwt.claim.role','authenticated',false),
      set_config('request.jwt.claims',json_build_object('sub',$1::text,'role','authenticated')::text,false),
      set_config('app.allow_ledger_ddl','1',false)`,
    [actor.auth_user_id]
  );

  const anomalies = (await client.query(`
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      b.warehouse_id::text as warehouse_id,
      coalesce(b.unit_cost,0) as old_unit_cost,
      round(coalesce(b.foreign_unit_cost,0) * coalesce(b.fx_rate_at_receipt,0), 6) as expected_unit_cost,
      greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) as remaining_qty,
      coalesce(b.min_margin_pct,0) as min_margin_pct
    from public.batches b
    where coalesce(b.status,'active')='active'
      and nullif(trim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(trim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency())
      and coalesce(b.fx_rate_at_receipt,0) > 0
      and coalesce(b.foreign_unit_cost,0) > 0
      and abs(coalesce(b.unit_cost,0)-round(coalesce(b.foreign_unit_cost,0)*coalesce(b.fx_rate_at_receipt,0),6)) > 0.01
    order by abs(coalesce(b.unit_cost,0)-round(coalesce(b.foreign_unit_cost,0)*coalesce(b.fx_rate_at_receipt,0),6)) desc
  `)).rows;
  out.anomalies_before_count = anomalies.length;

  const touchedPairs = new Set();
  for (const row of anomalies) {
    const batchId = String(row.batch_id);
    const itemId = String(row.item_id);
    const whId = String(row.warehouse_id);
    const oldCost = toNum(row.old_unit_cost);
    const newCost = toNum(row.expected_unit_cost);
    const remaining = toNum(row.remaining_qty);
    const minMargin = toNum(row.min_margin_pct);
    const deltaTotal = (newCost - oldCost) * remaining;
    try {
      await client.query('begin');
      await client.query(
        `update public.batches
         set unit_cost = round($2::numeric, 6),
             cost_per_unit = round($2::numeric, 6),
             min_selling_price = round(($2::numeric) * (1 + greatest(0, $3::numeric) / 100), 6),
             updated_at = now()
         where id = $1::uuid`,
        [batchId, newCost, minMargin]
      );

      if (remaining > 0.000001 && Math.abs(deltaTotal) > 0.01) {
        const lines = deltaTotal > 0
          ? [
              { accountCode: '1410', debit: Number(deltaTotal.toFixed(6)), credit: 0, memo: 'FX batch revaluation increase' },
              { accountCode: '4021', debit: 0, credit: Number(deltaTotal.toFixed(6)), memo: 'FX batch revaluation gain' },
            ]
          : [
              { accountCode: '5020', debit: Number(Math.abs(deltaTotal).toFixed(6)), credit: 0, memo: 'FX batch revaluation loss' },
              { accountCode: '1410', debit: 0, credit: Number(Math.abs(deltaTotal).toFixed(6)), memo: 'FX batch revaluation decrease' },
            ];
        const jr = (await client.query(
          `select public.create_manual_journal_entry($1::timestamptz, $2::text, $3::jsonb, null) as id`,
          [new Date().toISOString(), `FX revaluation ${batchId.slice(0, 8)} item ${itemId}`, JSON.stringify(lines)]
        )).rows[0]?.id;
        if (jr) {
          await client.query(`select public.approve_journal_entry($1::uuid)`, [jr]);
          out.journals_created.push({ batch_id: batchId, journal_entry_id: jr, delta_total: Number(deltaTotal.toFixed(6)) });
        }
      }
      await client.query('commit');
      out.batches_fixed.push({
        batch_id: batchId,
        old_unit_cost: oldCost,
        new_unit_cost: Number(newCost.toFixed(6)),
        remaining_qty: remaining,
        delta_total: Number(deltaTotal.toFixed(6)),
      });
      touchedPairs.add(`${itemId}|${whId}`);
    } catch (e) {
      await client.query('rollback');
      out.failures.push({ batch_id: batchId, error: String(e?.message || e) });
    }
  }

  for (const pair of touchedPairs) {
    const [itemId, whId] = pair.split('|');
    await client.query(
      `with calc as (
         select
           sum(
             greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)
             * coalesce(b.unit_cost,0)
           ) / nullif(
             sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)), 0
           ) as avg_cost
         from public.batches b
         where b.item_id::text = $1::text
           and b.warehouse_id = $2::uuid
           and coalesce(b.status,'active')='active'
       )
       update public.stock_management sm
       set avg_cost = round(coalesce(c.avg_cost, sm.avg_cost), 6),
           updated_at = now(),
           last_updated = now()
       from calc c
       where sm.item_id::text = $1::text
         and sm.warehouse_id = $2::uuid`,
      [itemId, whId]
    );
    await client.query(
      `update public.menu_items mi
       set cost_price = round(coalesce(sm.avg_cost, mi.cost_price), 6),
           updated_at = now()
       from public.stock_management sm
       where mi.id::text = $1::text
         and sm.item_id::text = $1::text
         and sm.warehouse_id = $2::uuid`,
      [itemId, whId]
    );
  }

  const after = (await client.query(`
    select count(*)::int as c
    from public.batches b
    where coalesce(b.status,'active')='active'
      and nullif(trim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(trim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency())
      and coalesce(b.fx_rate_at_receipt,0) > 0
      and coalesce(b.foreign_unit_cost,0) > 0
      and abs(coalesce(b.unit_cost,0)-round(coalesce(b.foreign_unit_cost,0)*coalesce(b.fx_rate_at_receipt,0),6)) > 0.01
  `)).rows[0]?.c;
  out.anomalies_after_count = Number(after || 0);
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_inventory_management_phase3_fx_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
