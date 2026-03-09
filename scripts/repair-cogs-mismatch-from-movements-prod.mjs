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

await client.connect();
const out = {
  generated_at: new Date().toISOString(),
  range_days: 180,
  mismatches_before: [],
  repaired_orders: [],
  skipped_orders: [],
  mismatches_after: [],
};

try {
  const mismatchRes = await client.query(`
    with delivered as (
      select o.id, o.created_at
      from public.orders o
      where o.status='delivered'
        and o.created_at >= now() - interval '180 days'
        and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
    ),
    oic as (
      select order_id, sum(coalesce(total_cost,0)) as oic_cost
      from public.order_item_cogs
      group by order_id
    ),
    mv as (
      select (reference_id)::uuid as order_id,
             sum(coalesce(nullif(total_cost,0), quantity*coalesce(nullif(unit_cost,0),0),0)) as mv_cost
      from public.inventory_movements
      where reference_table='orders'
        and movement_type='sale_out'
        and occurred_at >= now() - interval '180 days'
      group by (reference_id)::uuid
    )
    select
      d.id::text as order_id,
      d.created_at,
      coalesce(oic.oic_cost,0) as oic_cost,
      coalesce(mv.mv_cost,0) as mv_cost,
      (coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) as delta
    from delivered d
    join oic on oic.order_id=d.id
    join mv on mv.order_id=d.id
    where abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) > 0.01
    order by abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) desc
  `);

  out.mismatches_before = mismatchRes.rows || [];

  for (const row of out.mismatches_before) {
    const orderId = String(row.order_id);
    await client.query('begin');
    try {
      const sales = await client.query(`
        with sale_lines as (
          select
            im.item_id::text as item_id_text,
            sum(coalesce(im.quantity, 0)) as qty,
            sum(
              coalesce(
                nullif(im.total_cost, 0),
                im.quantity * coalesce(nullif(b.unit_cost, 0), nullif(im.unit_cost, 0), 0),
                0
              )
            ) as cost_sum
          from public.inventory_movements im
          left join public.batches b on b.id = im.batch_id
          where im.reference_table = 'orders'
            and im.movement_type = 'sale_out'
            and im.reference_id = $1
          group by im.item_id::text
        ),
        with_fallback as (
          select
            sl.item_id_text,
            sl.qty,
            case
              when sl.cost_sum > 0 then sl.cost_sum
              else sl.qty * coalesce(nullif(sm.avg_cost, 0), nullif(mi.cost_price, 0), 0)
            end as total_cost
          from sale_lines sl
          left join public.stock_management sm on sm.item_id::text = sl.item_id_text
          left join public.menu_items mi on mi.id::text = sl.item_id_text
        )
        select
          item_id_text,
          qty,
          case when qty > 0 then total_cost / qty else 0 end as unit_cost,
          total_cost
        from with_fallback
        where qty > 0 and total_cost >= 0
      `, [orderId]);

      if (!sales.rows.length) {
        await client.query('rollback');
        out.skipped_orders.push({ order_id: orderId, reason: 'no_sale_lines' });
        continue;
      }

      const beforeOic = await client.query(
        `select coalesce(sum(total_cost),0) as c from public.order_item_cogs where order_id=$1::uuid`,
        [orderId]
      );
      const beforeMv = await client.query(
        `select coalesce(sum(coalesce(nullif(im.total_cost,0), im.quantity*coalesce(nullif(im.unit_cost,0),0),0)),0) as c
         from public.inventory_movements im
         where im.reference_table='orders' and im.movement_type='sale_out' and im.reference_id=$1`,
        [orderId]
      );

      await client.query(`delete from public.order_item_cogs where order_id=$1::uuid`, [orderId]);
      for (const s of sales.rows) {
        await client.query(
          `insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
           values ($1::uuid, $2, $3, $4, $5, now())`,
          [orderId, String(s.item_id_text), n(s.qty), n(s.unit_cost), n(s.total_cost)]
        );
      }

      const afterOic = await client.query(
        `select coalesce(sum(total_cost),0) as c from public.order_item_cogs where order_id=$1::uuid`,
        [orderId]
      );
      const deltaAfter = n(afterOic.rows?.[0]?.c) - n(beforeMv.rows?.[0]?.c);

      await client.query('commit');
      out.repaired_orders.push({
        order_id: orderId,
        before_oic: n(beforeOic.rows?.[0]?.c),
        movement_cost: n(beforeMv.rows?.[0]?.c),
        after_oic: n(afterOic.rows?.[0]?.c),
        delta_after: deltaAfter,
      });
    } catch (e) {
      await client.query('rollback');
      out.skipped_orders.push({ order_id: orderId, reason: String(e?.message || e || '') });
    }
  }

  const afterRes = await client.query(`
    with delivered as (
      select o.id
      from public.orders o
      where o.status='delivered'
        and o.created_at >= now() - interval '180 days'
        and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
    ),
    oic as (
      select order_id, sum(coalesce(total_cost,0)) as oic_cost
      from public.order_item_cogs
      group by order_id
    ),
    mv as (
      select (reference_id)::uuid as order_id,
             sum(coalesce(nullif(total_cost,0), quantity*coalesce(nullif(unit_cost,0),0),0)) as mv_cost
      from public.inventory_movements
      where reference_table='orders'
        and movement_type='sale_out'
        and occurred_at >= now() - interval '180 days'
      group by (reference_id)::uuid
    )
    select
      d.id::text as order_id,
      coalesce(oic.oic_cost,0) as oic_cost,
      coalesce(mv.mv_cost,0) as mv_cost,
      (coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) as delta
    from delivered d
    join oic on oic.order_id=d.id
    join mv on mv.order_id=d.id
    where abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) > 0.01
    order by abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) desc
  `);
  out.mismatches_after = afterRes.rows || [];
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'backups', 'cogs_mismatch_repair_from_movements_prod.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
