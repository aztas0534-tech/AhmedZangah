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
const isUuid = (s) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(s || ''));

const out = {
  generated_at: new Date().toISOString(),
  anomalies_before: 0,
  total_delta_before: 0,
  sale_moves: [],
  return_increments: [],
  failures: [],
  anomalies_after: 0,
  total_delta_after: 0,
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
    with f as (
      select
        pi.purchase_order_id::text as po_id,
        pi.item_id::text as item_id,
        case when sum(coalesce(pi.quantity,0)) > 0
          then sum(coalesce(pi.qty_base,coalesce(pi.quantity,0))) / sum(coalesce(pi.quantity,0))
          else 1 end as factor
      from public.purchase_items pi
      group by pi.purchase_order_id::text, pi.item_id::text
    ),
    exp as (
      select
        pr.id::text as return_id,
        pr.purchase_order_id::text as po_id,
        pri.item_id::text as item_id,
        sum(pri.quantity) as qty_uom,
        coalesce(f.factor,1) as factor,
        sum(pri.quantity) * coalesce(f.factor,1) as expected_base,
        min(pr.created_at) as occurred_at
      from public.purchase_returns pr
      join public.purchase_return_items pri on pri.return_id=pr.id
      left join f on f.po_id=pr.purchase_order_id::text and f.item_id=pri.item_id::text
      group by pr.id::text, pr.purchase_order_id::text, pri.item_id::text, coalesce(f.factor,1)
    ),
    got as (
      select
        im.reference_id::text as return_id,
        im.item_id::text as item_id,
        sum(im.quantity) as actual_base
      from public.inventory_movements im
      where im.movement_type='return_out'
        and im.reference_table='purchase_returns'
      group by im.reference_id::text, im.item_id::text
    )
    select
      e.return_id, e.po_id, e.item_id, e.factor, e.qty_uom, e.expected_base, coalesce(g.actual_base,0) as actual_base,
      (e.expected_base - coalesce(g.actual_base,0)) as delta_base,
      e.occurred_at
    from exp e
    left join got g on g.return_id=e.return_id and g.item_id=e.item_id
    where (e.expected_base - coalesce(g.actual_base,0)) > 0.0001
    order by (e.expected_base - coalesce(g.actual_base,0)) desc
  `)).rows;

  out.anomalies_before = anomalies.length;
  out.total_delta_before = anomalies.reduce((s, a) => s + toNum(a.delta_base), 0);

  const items = [...new Set(anomalies.map((a) => String(a.item_id)))];

  const batches = (await client.query(`
    with out_mv as (
      select
        im.batch_id::text as batch_id,
        sum(case when im.movement_type='sale_out' then im.quantity else 0 end) as sale_out,
        sum(case when im.movement_type='return_out' then im.quantity else 0 end) as return_out,
        sum(case when im.movement_type='wastage_out' then im.quantity else 0 end) as wastage_out,
        sum(case when im.movement_type='adjust_out' then im.quantity else 0 end) as adjust_out,
        sum(case when im.movement_type='transfer_out' then im.quantity else 0 end) as transfer_out
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.batch_id::text
    )
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      b.warehouse_id::text as warehouse_id,
      coalesce(b.status,'active') as status,
      coalesce(b.qc_status,'released') as qc_status,
      coalesce(b.quantity_received,0) as quantity_received,
      coalesce(o.sale_out,0) as sale_out,
      coalesce(o.return_out,0) as return_out,
      coalesce(o.wastage_out,0) as wastage_out,
      coalesce(o.adjust_out,0) as adjust_out,
      coalesce(o.transfer_out,0) as transfer_out,
      (coalesce(b.quantity_received,0) - (coalesce(o.sale_out,0)+coalesce(o.return_out,0)+coalesce(o.wastage_out,0)+coalesce(o.adjust_out,0)+coalesce(o.transfer_out,0))) as capacity,
      coalesce(b.unit_cost,0) as unit_cost,
      pr.purchase_order_id::text as po_id
    from public.batches b
    left join out_mv o on o.batch_id=b.id::text
    left join public.purchase_receipts pr on pr.id=b.receipt_id
    where b.item_id::text = any($1::text[])
      and coalesce(b.status,'active')='active'
  `, [items])).rows.map((b) => ({ ...b, capacity: toNum(b.capacity), unit_cost: toNum(b.unit_cost) }));

  const sales = (await client.query(`
    select
      im.id::text as movement_id,
      im.item_id::text as item_id,
      im.warehouse_id::text as warehouse_id,
      im.batch_id::text as batch_id,
      im.quantity,
      im.reference_id,
      im.occurred_at
    from public.inventory_movements im
    where im.movement_type='sale_out'
      and im.batch_id is not null
      and im.item_id::text = any($1::text[])
    order by im.occurred_at asc
  `, [items])).rows.map((s) => ({ ...s, quantity: toNum(s.quantity) }));

  const returnsMovements = (await client.query(`
    select
      im.id::text as movement_id,
      im.item_id::text as item_id,
      im.warehouse_id::text as warehouse_id,
      im.batch_id::text as batch_id,
      im.quantity,
      im.reference_id::text as return_id,
      im.occurred_at
    from public.inventory_movements im
    where im.movement_type='return_out'
      and im.reference_table='purchase_returns'
      and im.item_id::text = any($1::text[])
    order by im.occurred_at asc
  `, [items])).rows.map((r) => ({ ...r, quantity: toNum(r.quantity) }));

  const batchById = new Map(batches.map((b) => [String(b.batch_id), b]));
  const salesByBatch = new Map();
  for (const s of sales) {
    const k = String(s.batch_id);
    const arr = salesByBatch.get(k) || [];
    arr.push(s);
    salesByBatch.set(k, arr);
  }

  const findAltBatch = (sale, poIdToAvoid) => {
    const cands = batches
      .filter((b) =>
        String(b.item_id) === String(sale.item_id) &&
        String(b.warehouse_id) === String(sale.warehouse_id) &&
        String(b.po_id || '') !== String(poIdToAvoid || '') &&
        String(b.status || 'active') === 'active' &&
        String(b.qc_status || 'released') === 'released' &&
        toNum(b.capacity) >= toNum(sale.quantity) + 1e-9
      )
      .sort((a, b) => toNum(b.capacity) - toNum(a.capacity));
    return cands[0] || null;
  };

  for (const an of anomalies) {
    const itemId = String(an.item_id);
    const poId = String(an.po_id);
    let need = toNum(an.delta_base);
    const returnId = String(an.return_id);

    const targetBatches = batches
      .filter((b) =>
        String(b.item_id) === itemId &&
        String(b.po_id || '') === poId &&
        String(b.status || 'active') === 'active'
      )
      .sort((a, b) => toNum(b.capacity) - toNum(a.capacity));

    if (!targetBatches.length) {
      out.failures.push({ return_id: returnId, item_id: itemId, reason: 'NO_TARGET_BATCHES_FOR_PO' });
      continue;
    }

    let totalCap = targetBatches.reduce((s, b) => s + Math.max(0, toNum(b.capacity)), 0);
    if (totalCap + 1e-9 < need) {
      for (const tb of targetBatches) {
        if (totalCap + 1e-9 >= need) break;
        const salesOnTb = (salesByBatch.get(String(tb.batch_id)) || []).sort((x, y) => toNum(x.quantity) - toNum(y.quantity));
        for (const sm of salesOnTb) {
          if (totalCap + 1e-9 >= need) break;
          const alt = findAltBatch(sm, poId);
          if (!alt) continue;

          await client.query('begin');
          try {
            await client.query(`set local session_replication_role = 'replica'`);
            const newUnit = toNum(alt.unit_cost);
            const newTotal = Number((toNum(sm.quantity) * newUnit).toFixed(6));
            await client.query(
              `update public.inventory_movements
               set batch_id = $2::uuid,
                   unit_cost = $3::numeric,
                   total_cost = $4::numeric,
                   data = coalesce(data,'{}'::jsonb) || jsonb_build_object('batchId',$2::text,'phase4SaleMove',true)
               where id = $1::uuid`,
              [sm.movement_id, alt.batch_id, newUnit, newTotal]
            );
            await client.query('commit');
          } catch (e) {
            await client.query('rollback');
            out.failures.push({ movement_id: sm.movement_id, reason: `SALE_MOVE_FAIL:${String(e?.message || e)}` });
            continue;
          }

          try {
            await client.query(`select public.post_inventory_movement($1::uuid)`, [sm.movement_id]);
          } catch {}
          if (isUuid(sm.reference_id)) {
            try {
              await client.query(`select public.sync_order_item_cogs_from_sale_out($1::uuid)`, [sm.reference_id]);
            } catch {}
          }

          const fromBatch = batchById.get(String(tb.batch_id));
          const toBatch = batchById.get(String(alt.batch_id));
          if (fromBatch) fromBatch.capacity += toNum(sm.quantity);
          if (toBatch) toBatch.capacity -= toNum(sm.quantity);
          totalCap += toNum(sm.quantity);
          out.sale_moves.push({
            movement_id: sm.movement_id,
            qty: toNum(sm.quantity),
            from_batch_id: tb.batch_id,
            to_batch_id: alt.batch_id,
            new_unit_cost: toNum(alt.unit_cost),
          });
          sm.batch_id = String(alt.batch_id);
        }
      }
    }

    if (totalCap + 1e-9 < need) {
      out.failures.push({ return_id: returnId, item_id: itemId, reason: 'INSUFFICIENT_CAPACITY_AFTER_SALE_MOVES', need, totalCap });
      continue;
    }

    const returnRows = returnsMovements
      .filter((r) => String(r.return_id) === returnId && String(r.item_id) === itemId)
      .sort((a, b) => toNum(b.quantity) - toNum(a.quantity));
    if (!returnRows.length) {
      out.failures.push({ return_id: returnId, item_id: itemId, reason: 'NO_RETURN_MOVEMENTS_TO_ADJUST' });
      continue;
    }

    for (const tb of targetBatches) {
      if (need <= 0.0001) break;
      let cap = Math.max(0, toNum(tb.capacity));
      if (cap <= 0.0001) continue;
      const take = Math.min(cap, need);
      const rr = returnRows.find((r) => String(r.batch_id) === String(tb.batch_id)) || returnRows[0];
      const newQty = toNum(rr.quantity) + take;
      const unit = toNum(tb.unit_cost);
      const newTotal = Number((newQty * unit).toFixed(6));

      await client.query('begin');
      try {
        await client.query(`set local session_replication_role = 'replica'`);
        await client.query(
          `update public.inventory_movements
           set quantity = $2::numeric,
               unit_cost = $3::numeric,
               total_cost = $4::numeric,
               batch_id = $5::uuid,
               occurred_at = coalesce(occurred_at, $6::timestamptz),
               data = coalesce(data,'{}'::jsonb) || jsonb_build_object('batchId',$5::text,'phase4ReturnFix',true)
           where id = $1::uuid`,
          [rr.movement_id, newQty, unit, newTotal, tb.batch_id, an.occurred_at]
        );
        await client.query('commit');
      } catch (e) {
        await client.query('rollback');
        out.failures.push({ movement_id: rr.movement_id, reason: `RETURN_INC_FAIL:${String(e?.message || e)}` });
        continue;
      }
      try {
        await client.query(`select public.post_inventory_movement($1::uuid)`, [rr.movement_id]);
      } catch {}

      rr.quantity = newQty;
      rr.batch_id = String(tb.batch_id);
      tb.capacity -= take;
      need -= take;
      out.return_increments.push({
        return_id: returnId,
        item_id: itemId,
        movement_id: rr.movement_id,
        batch_id: tb.batch_id,
        added_qty: Number(take.toFixed(6)),
      });
    }

    if (need > 0.0001) {
      out.failures.push({ return_id: returnId, item_id: itemId, reason: 'DELTA_NOT_FULLY_ALLOCATED', remaining_delta: need });
    }
  }

  const after = (await client.query(`
    with f as (
      select
        pi.purchase_order_id::text as po_id,
        pi.item_id::text as item_id,
        case when sum(coalesce(pi.quantity,0)) > 0
          then sum(coalesce(pi.qty_base,coalesce(pi.quantity,0))) / sum(coalesce(pi.quantity,0))
          else 1 end as factor
      from public.purchase_items pi
      group by pi.purchase_order_id::text, pi.item_id::text
    ),
    exp as (
      select
        pr.id::text as return_id,
        pr.purchase_order_id::text as po_id,
        pri.item_id::text as item_id,
        sum(pri.quantity) * coalesce(f.factor,1) as expected_base
      from public.purchase_returns pr
      join public.purchase_return_items pri on pri.return_id=pr.id
      left join f on f.po_id=pr.purchase_order_id::text and f.item_id=pri.item_id::text
      group by pr.id::text, pr.purchase_order_id::text, pri.item_id::text, coalesce(f.factor,1)
    ),
    got as (
      select
        im.reference_id::text as return_id,
        im.item_id::text as item_id,
        sum(im.quantity) as actual_base
      from public.inventory_movements im
      where im.movement_type='return_out'
        and im.reference_table='purchase_returns'
      group by im.reference_id::text, im.item_id::text
    )
    select
      count(*) filter (where abs(coalesce(g.actual_base,0)-e.expected_base)>0.0001)::int as mismatch_rows,
      coalesce(sum(e.expected_base-coalesce(g.actual_base,0)) filter (where e.expected_base-coalesce(g.actual_base,0)>0.0001),0) as positive_delta_total
    from exp e
    left join got g on g.return_id=e.return_id and g.item_id=e.item_id
  `)).rows[0];

  out.anomalies_after = Number(after?.mismatch_rows || 0);
  out.total_delta_after = toNum(after?.positive_delta_total);
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_purchase_returns_uom_base_all_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
