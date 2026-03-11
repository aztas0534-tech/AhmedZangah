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

const out = {
  generated_at: new Date().toISOString(),
  mode: 'targeted_anomalous_items_all_time',
  affected_items: [],
  target_orders_count: 0,
  before_mismatch_orders: 0,
  repaired_orders: 0,
  skipped_orders: [],
  after_mismatch_orders: 0,
  delta_before_total: 0,
  delta_after_total: 0,
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
      set_config('request.jwt.claim.sub', $1::text, false),
      set_config('request.jwt.claim.role', 'authenticated', false),
      set_config('request.jwt.claims', json_build_object('sub',$1::text,'role','authenticated')::text, false)`,
    [actor.auth_user_id]
  );

  const productReport = (await client.query(
    `select item_id,total_sales,total_cost,quantity_sold
     from public.get_product_sales_report_v9($1::timestamptz,$2::timestamptz,$3::uuid,$4::boolean)`,
    ['1970-01-01T00:00:00.000Z', new Date().toISOString(), null, false]
  )).rows;

  const anomalousItems = productReport
    .filter((r) => {
      const sales = n(r.total_sales);
      const cost = n(r.total_cost);
      const qty = n(r.quantity_sold);
      return (sales > 0 && cost === 0) || (cost > sales + 0.01) || (sales > 0 && qty <= 0) || (sales > 0 && (cost / sales) > 1.5);
    })
    .map((r) => String(r.item_id));

  out.affected_items = anomalousItems;
  if (!anomalousItems.length) {
    const outPath = path.join(process.cwd(), 'targeted_cogs_repair_result.json');
    fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
    console.log(outPath);
    process.exit(0);
  }

  const targetOrdersRes = await client.query(
    `select distinct o.id::text as order_id
     from public.orders o
     join public.inventory_movements im
       on im.reference_table='orders'
      and im.movement_type='sale_out'
      and im.reference_id=o.id::text
     where o.status='delivered'
       and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
       and im.item_id::text = any($1::text[])`,
    [anomalousItems]
  );
  const targetOrders = targetOrdersRes.rows.map((r) => String(r.order_id));
  out.target_orders_count = targetOrders.length;

  if (!targetOrders.length) {
    const outPath = path.join(process.cwd(), 'targeted_cogs_repair_result.json');
    fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
    console.log(outPath);
    process.exit(0);
  }

  const beforeMismatchRes = await client.query(
    `with oic as (
       select order_id::text as order_id, sum(coalesce(total_cost,0)) as oic_cost
       from public.order_item_cogs
       where order_id::text = any($1::text[])
       group by order_id::text
     ), mv as (
       select reference_id as order_id,
              sum(coalesce(nullif(total_cost,0), quantity*coalesce(nullif(unit_cost,0),0),0)) as mv_cost
       from public.inventory_movements
       where reference_table='orders'
         and movement_type='sale_out'
         and reference_id = any($1::text[])
       group by reference_id
     )
     select coalesce(sum(abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0))),0) as total_abs_delta,
            count(*) filter (where abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) > 0.01) as mismatch_count
     from mv
     left join oic on oic.order_id = mv.order_id`,
    [targetOrders]
  );
  out.before_mismatch_orders = Number(beforeMismatchRes.rows[0].mismatch_count || 0);
  out.delta_before_total = n(beforeMismatchRes.rows[0].total_abs_delta);

  for (const orderId of targetOrders) {
    await client.query('begin');
    try {
      const sales = await client.query(
        `with sale_lines as (
           select
             im.item_id::text as item_id_text,
             sum(coalesce(im.quantity,0)) as qty,
             sum(coalesce(nullif(im.total_cost,0), im.quantity * coalesce(nullif(b.unit_cost,0), nullif(im.unit_cost,0), 0), 0)) as cost_sum
           from public.inventory_movements im
           left join public.batches b on b.id = im.batch_id
           where im.reference_table='orders'
             and im.movement_type='sale_out'
             and im.reference_id=$1
           group by im.item_id::text
         ), with_fallback as (
           select
             sl.item_id_text,
             sl.qty,
             case when sl.cost_sum > 0 then sl.cost_sum else sl.qty * coalesce(nullif(sm.avg_cost,0), nullif(mi.cost_price,0), 0) end as total_cost
           from sale_lines sl
           left join public.stock_management sm on sm.item_id::text = sl.item_id_text
           left join public.menu_items mi on mi.id::text = sl.item_id_text
         )
         select item_id_text, qty,
                case when qty > 0 then total_cost/qty else 0 end as unit_cost,
                total_cost
         from with_fallback
         where qty > 0 and total_cost >= 0`,
        [orderId]
      );

      if (!sales.rows.length) {
        await client.query('rollback');
        out.skipped_orders.push({ order_id: orderId, reason: 'no_sale_lines' });
        continue;
      }

      await client.query(`delete from public.order_item_cogs where order_id=$1::uuid`, [orderId]);
      for (const s of sales.rows) {
        await client.query(
          `insert into public.order_item_cogs(order_id,item_id,quantity,unit_cost,total_cost,created_at)
           values ($1::uuid,$2,$3,$4,$5,now())`,
          [orderId, String(s.item_id_text), n(s.qty), n(s.unit_cost), n(s.total_cost)]
        );
      }

      await client.query('commit');
      out.repaired_orders += 1;
    } catch (e) {
      await client.query('rollback');
      out.skipped_orders.push({ order_id: orderId, reason: String(e?.message || e) });
    }
  }

  const afterMismatchRes = await client.query(
    `with oic as (
       select order_id::text as order_id, sum(coalesce(total_cost,0)) as oic_cost
       from public.order_item_cogs
       where order_id::text = any($1::text[])
       group by order_id::text
     ), mv as (
       select reference_id as order_id,
              sum(coalesce(nullif(total_cost,0), quantity*coalesce(nullif(unit_cost,0),0),0)) as mv_cost
       from public.inventory_movements
       where reference_table='orders'
         and movement_type='sale_out'
         and reference_id = any($1::text[])
       group by reference_id
     )
     select coalesce(sum(abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0))),0) as total_abs_delta,
            count(*) filter (where abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) > 0.01) as mismatch_count
     from mv
     left join oic on oic.order_id = mv.order_id`,
    [targetOrders]
  );

  out.after_mismatch_orders = Number(afterMismatchRes.rows[0].mismatch_count || 0);
  out.delta_after_total = n(afterMismatchRes.rows[0].total_abs_delta);
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'targeted_cogs_repair_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
