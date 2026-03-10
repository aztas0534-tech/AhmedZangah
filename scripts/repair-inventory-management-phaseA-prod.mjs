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

const out = {
  generated_at: new Date().toISOString(),
  pre: {},
  steps: {},
  post: {},
  revalue_batches: [],
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

  const pre = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    ),
    bad as (
      select b.id
      from public.batches b
      left join out_mv o on o.batch_id=b.id::text
      where abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0))>0.0001
    ),
    fx as (
      select b.id
      from public.batches b
      where coalesce(b.status,'active')='active'
        and nullif(trim(coalesce(b.foreign_currency,'')), '') is not null
        and upper(trim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency())
        and coalesce(b.fx_rate_at_receipt,0) > 0
        and coalesce(b.foreign_unit_cost,0) > 0
        and abs(coalesce(b.unit_cost,0)-round(coalesce(b.foreign_unit_cost,0)*coalesce(b.fx_rate_at_receipt,0),6)) > 0.01
    )
    select
      (select count(*) from bad) as bad_batch_consumed_count,
      (select count(*) from fx) as fx_anomaly_count
  `)).rows[0];
  out.pre = pre;

  const step1 = await client.query(`
    with out_mv as (
      select im.batch_id::uuid as batch_id,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::uuid
    )
    update public.batches b
    set quantity_consumed = least(coalesce(b.quantity_received,0), greatest(coalesce(o.outbound_qty,0),0)),
        updated_at = now()
    from out_mv o
    where o.batch_id = b.id
      and abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0))>0.0001
  `);
  out.steps.recompute_batches_quantity_consumed_rows = step1.rowCount || 0;

  const hasBatchBalances = (await client.query(`
    select to_regclass('public.batch_balances') is not null as ok
  `)).rows[0]?.ok;
  if (hasBatchBalances) {
    const step2 = await client.query(`
      with net as (
        select
          im.item_id::text as item_id,
          im.batch_id::uuid as batch_id,
          im.warehouse_id,
          sum(
            case
              when im.movement_type in ('purchase_in','adjust_in','transfer_in') then im.quantity
              when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then -im.quantity
              else 0
            end
          ) as net_qty
        from public.inventory_movements im
        where im.batch_id is not null
        group by im.item_id::text, im.batch_id::uuid, im.warehouse_id
      )
      update public.batch_balances bb
      set quantity = greatest(coalesce(n.net_qty,0),0),
          updated_at = now()
      from net n
      where bb.batch_id = n.batch_id
        and bb.warehouse_id = n.warehouse_id
        and bb.item_id = n.item_id
        and abs(coalesce(bb.quantity,0)-greatest(coalesce(n.net_qty,0),0))>0.0001
    `);
    out.steps.recompute_batch_balances_rows = step2.rowCount || 0;
  } else {
    out.steps.recompute_batch_balances_rows = 0;
  }

  const rows = (await client.query(`
    select sm.item_id::text as item_id, sm.warehouse_id::text as warehouse_id
    from public.stock_management sm
  `)).rows;
  let recomputeCount = 0;
  for (const r of rows) {
    await client.query(`select public.recompute_stock_for_item($1::text,$2::uuid)`, [r.item_id, r.warehouse_id]);
    recomputeCount += 1;
  }
  out.steps.recompute_stock_for_item_rows = recomputeCount;

  const fxBatches = (await client.query(`
    select
      b.id::text as batch_id,
      round(coalesce(b.foreign_unit_cost,0) * coalesce(b.fx_rate_at_receipt,0), 6) as expected_cost
    from public.batches b
    where coalesce(b.status,'active')='active'
      and nullif(trim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(trim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency())
      and coalesce(b.fx_rate_at_receipt,0) > 0
      and coalesce(b.foreign_unit_cost,0) > 0
      and abs(coalesce(b.unit_cost,0)-round(coalesce(b.foreign_unit_cost,0)*coalesce(b.fx_rate_at_receipt,0),6)) > 0.01
  `)).rows;
  for (const b of fxBatches) {
    try {
      const r = (await client.query(
        `select public.revalue_batch_unit_cost($1::uuid,$2::numeric,$3::text,$4::boolean) as r`,
        [b.batch_id, b.expected_cost, 'inventory_full_audit_phaseA_fx_repair', true]
      )).rows[0]?.r;
      out.revalue_batches.push({ batch_id: b.batch_id, ok: true, result: r });
    } catch (e) {
      out.revalue_batches.push({ batch_id: b.batch_id, ok: false, error: String(e?.message || e) });
    }
  }

  const post = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    ),
    bad as (
      select b.id
      from public.batches b
      left join out_mv o on o.batch_id=b.id::text
      where abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0))>0.0001
    ),
    fx as (
      select b.id
      from public.batches b
      where coalesce(b.status,'active')='active'
        and nullif(trim(coalesce(b.foreign_currency,'')), '') is not null
        and upper(trim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency())
        and coalesce(b.fx_rate_at_receipt,0) > 0
        and coalesce(b.foreign_unit_cost,0) > 0
        and abs(coalesce(b.unit_cost,0)-round(coalesce(b.foreign_unit_cost,0)*coalesce(b.fx_rate_at_receipt,0),6)) > 0.01
    )
    select
      (select count(*) from bad) as bad_batch_consumed_count,
      (select count(*) from fx) as fx_anomaly_count
  `)).rows[0];
  out.post = post;
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_inventory_management_phaseA_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
