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

const n = (v) => Number(v || 0) || 0;
const isUuid = (s) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(s || ''));

const out = {
  generated_at: new Date().toISOString(),
  orphan_candidates_before: 0,
  cogs_candidates_before: 0,
  orphan_batches_deactivated: [],
  sale_cogs_fixed: [],
  impacted_items: [],
  failures: [],
  orphan_candidates_after: 0,
  cogs_candidates_after: 0,
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

  const orphanRows = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
        sum(case when im.movement_type in ('purchase_in','adjust_in','transfer_in') then im.quantity else 0 end) as inbound_qty,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      b.warehouse_id::text as warehouse_id,
      b.quantity_received,
      b.quantity_consumed,
      b.unit_cost,
      b.qc_status
    from public.batches b
    left join public.purchase_receipts pr on pr.id=b.receipt_id
    left join out_mv o on o.batch_id=b.id::text
    where coalesce(b.status,'active')='active'
      and pr.id is null
      and coalesce(o.inbound_qty,0)=0
      and coalesce(o.outbound_qty,0)=0
      and coalesce(b.quantity_consumed,0)=0
      and coalesce(b.quantity_received,0) <= 2
  `)).rows;
  out.orphan_candidates_before = orphanRows.length;

  const cogsRows = (await client.query(`
    select
      im.id::text as movement_id,
      im.reference_id::text as order_id,
      im.batch_id::text as batch_id,
      im.item_id::text as item_id,
      im.quantity,
      im.unit_cost as old_unit_cost,
      b.unit_cost as batch_unit_cost
    from public.inventory_movements im
    join public.batches b on b.id=im.batch_id
    where im.movement_type='sale_out'
      and im.reference_table='orders'
      and coalesce(im.unit_cost,0)>0
      and coalesce(b.unit_cost,0)>0
      and abs(im.unit_cost-b.unit_cost)>greatest(1,abs(b.unit_cost)*0.8)
      and greatest(im.unit_cost,b.unit_cost)/least(im.unit_cost,b.unit_cost)>=20
  `)).rows;
  out.cogs_candidates_before = cogsRows.length;

  await client.query('begin');
  try {
    await client.query(`set local session_replication_role = 'replica'`);
    for (const b of orphanRows) {
      await client.query(
        `update public.batches
         set status='inactive',
             quantity_received=0,
             quantity_consumed=0,
             quantity_transferred=0,
             data = coalesce(data,'{}'::jsonb) || jsonb_build_object('manualRepair','global_orphan_batch_cleanup_no_movements'),
             updated_at=now()
         where id=$1::uuid`,
        [b.batch_id]
      );
      out.orphan_batches_deactivated.push({
        batch_id: b.batch_id,
        item_id: b.item_id,
        old_qty: n(b.quantity_received),
        old_unit_cost: n(b.unit_cost),
      });
    }
    for (const s of cogsRows) {
      const unit = n(s.batch_unit_cost);
      const total = Number((n(s.quantity) * unit).toFixed(6));
      await client.query(
        `update public.inventory_movements
         set unit_cost=$2::numeric,
             total_cost=$3::numeric,
             data=coalesce(data,'{}'::jsonb) || jsonb_build_object('manualRepair','global_fix_sale_out_unit_cost_from_batch')
         where id=$1::uuid`,
        [s.movement_id, unit, total]
      );
      out.sale_cogs_fixed.push({
        movement_id: s.movement_id,
        order_id: s.order_id,
        item_id: s.item_id,
        qty: n(s.quantity),
        old_unit_cost: n(s.old_unit_cost),
        new_unit_cost: unit,
      });
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }

  for (const s of out.sale_cogs_fixed) {
    try {
      await client.query(`select public.post_inventory_movement($1::uuid)`, [s.movement_id]);
    } catch (e) {
      out.failures.push({ movement_id: s.movement_id, reason: `post_inventory_movement:${String(e?.message || e)}` });
    }
    if (isUuid(s.order_id)) {
      try {
        await client.query(`select public.sync_order_item_cogs_from_sale_out($1::uuid)`, [s.order_id]);
      } catch (e) {
        out.failures.push({ movement_id: s.movement_id, reason: `sync_order_item_cogs:${String(e?.message || e)}` });
      }
    }
  }

  const impactedItems = [...new Set([
    ...out.orphan_batches_deactivated.map((x) => String(x.item_id)),
    ...out.sale_cogs_fixed.map((x) => String(x.item_id)),
  ])];
  out.impacted_items = impactedItems;

  if (impactedItems.length > 0) {
    const whRows = (await client.query(`
      select distinct warehouse_id::text as warehouse_id
      from public.stock_management
      where item_id::text = any($1::text[])
    `, [impactedItems])).rows;
    for (const itemId of impactedItems) {
      for (const wr of whRows) {
        try {
          await client.query(`select public.recompute_stock_for_item($1::text,$2::uuid)`, [itemId, wr.warehouse_id]);
        } catch (e) {
          out.failures.push({ item_id: itemId, warehouse_id: wr.warehouse_id, reason: `recompute_stock:${String(e?.message || e)}` });
        }
      }
    }

    await client.query(`
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
        and b.item_id::text = any($1::text[])
        and abs(coalesce(b.quantity_consumed,0)-coalesce(o.outbound_qty,0))>0.0001
    `, [impactedItems]);

    await client.query(`
      with calc as (
        select b.item_id::text as item_id, b.warehouse_id,
               sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)*coalesce(b.unit_cost,0))
               / nullif(sum(greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0)),0) as avg_cost
        from public.batches b
        where b.item_id::text = any($1::text[])
          and coalesce(b.status,'active')='active'
          and coalesce(b.qc_status,'released')='released'
        group by b.item_id::text,b.warehouse_id
      )
      update public.stock_management sm
      set avg_cost=round(coalesce(c.avg_cost,sm.avg_cost),6), updated_at=now(), last_updated=now()
      from calc c
      where sm.item_id::text=c.item_id and sm.warehouse_id=c.warehouse_id
    `, [impactedItems]);

    await client.query(`
      update public.menu_items mi
      set cost_price=round(sm.avg_cost,6), updated_at=now()
      from public.stock_management sm
      where mi.id::text=sm.item_id::text
        and mi.id::text = any($1::text[])
    `, [impactedItems]);
  }

  const after = (await client.query(`
    with out_mv as (
      select im.batch_id::text as batch_id,
        sum(case when im.movement_type in ('purchase_in','adjust_in','transfer_in') then im.quantity else 0 end) as inbound_qty,
        sum(case when im.movement_type in ('sale_out','return_out','wastage_out','adjust_out','transfer_out') then im.quantity else 0 end) as outbound_qty
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    ),
    cand as (
      select b.id
      from public.batches b
      left join public.purchase_receipts pr on pr.id=b.receipt_id
      left join out_mv o on o.batch_id=b.id::text
      where coalesce(b.status,'active')='active'
        and pr.id is null
        and coalesce(o.inbound_qty,0)=0
        and coalesce(o.outbound_qty,0)=0
        and coalesce(b.quantity_consumed,0)=0
        and coalesce(b.quantity_received,0) <= 2
    ),
    cogs as (
      select im.id
      from public.inventory_movements im
      join public.batches b on b.id=im.batch_id
      where im.movement_type='sale_out'
        and im.reference_table='orders'
        and coalesce(im.unit_cost,0)>0
        and coalesce(b.unit_cost,0)>0
        and abs(im.unit_cost-b.unit_cost)>greatest(1,abs(b.unit_cost)*0.8)
        and greatest(im.unit_cost,b.unit_cost)/least(im.unit_cost,b.unit_cost)>=20
    )
    select
      (select count(*) from cand)::int as orphan_candidates_after,
      (select count(*) from cogs)::int as cogs_candidates_after
  `)).rows[0];
  out.orphan_candidates_after = Number(after?.orphan_candidates_after || 0);
  out.cogs_candidates_after = Number(after?.cogs_candidates_after || 0);
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_global_orphan_batches_and_cogs_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
