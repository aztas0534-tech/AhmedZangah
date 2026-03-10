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

const start = '1970-01-01T00:00:00.000Z';
const end = new Date().toISOString();
const n = (v) => Number(v || 0);
const r2 = (x) => Math.round((Number(x) || 0) * 100) / 100;

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

  const reportRows = (await client.query(
    `select * from public.get_product_sales_report_v9($1::timestamptz,$2::timestamptz,$3::uuid,$4::boolean)`,
    [start, end, null, false]
  )).rows;

  const anomalies = reportRows.filter((r) => {
    const sales = n(r.total_sales);
    const cost = n(r.total_cost);
    const qty = n(r.quantity_sold);
    return (sales > 0 && cost === 0) || (cost > sales + 0.01) || (sales > 0 && qty <= 0) || (sales > 0 && (cost / sales) > 1.5);
  });

  const ids = anomalies.map((r) => String(r.item_id));
  if (!ids.length) {
    const out = { period: { start, end }, anomalies_total: 0, high_priority: 0, medium_priority: 0, items: [] };
    const outPath = path.join(process.cwd(), 'product_margin_rootcause_report_after_fix.json');
    fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
    console.log(outPath);
    process.exit(0);
  }

  const detailSql = `
with target_items as (
  select unnest($1::text[]) as item_id
), effective_orders as (
  select o.id
  from public.orders o
  where (o.status='delivered' or nullif(o.data->>'paidAt','') is not null)
    and coalesce(
      nullif(o.data->>'paidAt','')::timestamptz,
      nullif(o.data->>'deliveredAt','')::timestamptz,
      nullif(o.data->>'closedAt','')::timestamptz,
      o.created_at
    ) between $2::timestamptz and $3::timestamptz
), cogs as (
  select oic.item_id::text as item_id,
         count(*) as cogs_rows,
         coalesce(sum(oic.total_cost),0) as cogs_sum
  from public.order_item_cogs oic
  join effective_orders eo on eo.id = oic.order_id
  where oic.item_id::text in (select item_id from target_items)
  group by oic.item_id::text
), sale_out as (
  select im.item_id::text as item_id,
         count(*) as saleout_rows,
         coalesce(sum(im.quantity),0) as saleout_qty,
         coalesce(sum(abs(im.total_cost)),0) as saleout_cost
  from public.inventory_movements im
  join effective_orders eo on eo.id::text = im.reference_id
  where im.reference_table='orders'
    and im.movement_type='sale_out'
    and im.item_id::text in (select item_id from target_items)
  group by im.item_id::text
), ret_in as (
  select im.item_id::text as item_id,
         count(*) as returnin_rows,
         coalesce(sum(im.quantity),0) as returnin_qty,
         coalesce(sum(im.total_cost),0) as returnin_cost
  from public.inventory_movements im
  where im.reference_table='sales_returns'
    and im.movement_type='return_in'
    and im.occurred_at between $2::timestamptz and $3::timestamptz
    and im.item_id::text in (select item_id from target_items)
  group by im.item_id::text
), sm as (
  select sm.item_id::text as item_id,
         coalesce(sm.avg_cost,0) as avg_cost
  from public.stock_management sm
  where sm.item_id::text in (select item_id from target_items)
)
select t.item_id,
       coalesce(c.cogs_rows,0) as cogs_rows,
       coalesce(c.cogs_sum,0) as cogs_sum,
       coalesce(s.saleout_rows,0) as saleout_rows,
       coalesce(s.saleout_qty,0) as saleout_qty,
       coalesce(s.saleout_cost,0) as saleout_cost,
       coalesce(r.returnin_rows,0) as returnin_rows,
       coalesce(r.returnin_qty,0) as returnin_qty,
       coalesce(r.returnin_cost,0) as returnin_cost,
       coalesce(sm.avg_cost,0) as avg_cost
from target_items t
left join cogs c on c.item_id=t.item_id
left join sale_out s on s.item_id=t.item_id
left join ret_in r on r.item_id=t.item_id
left join sm on sm.item_id=t.item_id
order by t.item_id;
`;

  const detailRows = (await client.query(detailSql, [ids, start, end])).rows;
  const detailById = new Map(detailRows.map((r) => [String(r.item_id), r]));

  const analyzed = anomalies.map((r) => {
    const itemId = String(r.item_id);
    const d = detailById.get(itemId) || {};
    const sales = n(r.total_sales);
    const cost = n(r.total_cost);
    const qty = n(r.quantity_sold);
    const profit = n(r.total_profit);
    const cogsRows = n(d.cogs_rows);
    const cogsSum = n(d.cogs_sum);
    const saleoutQty = n(d.saleout_qty);
    const saleoutCost = n(d.saleout_cost);
    const retQty = n(d.returnin_qty);
    const avgCost = n(d.avg_cost);

    const reasons = [];
    if (sales > 0 && cost === 0) reasons.push('مبيعات بدون تكلفة');
    if (cost > sales + 0.01) reasons.push('تكلفة أعلى من صافي المبيعات');
    if (sales > 0 && qty <= 0) reasons.push('كمية صافية غير منطقية مقابل مبيعات');
    if (sales > 0 && (cost / sales) > 1.5) reasons.push('نسبة تكلفة إلى مبيعات مرتفعة جداً');
    if (cogsRows === 0 && cost > 0) reasons.push('COGS غير موجود والاعتماد على fallback');
    if (Math.abs(cogsSum - saleoutCost) > 0.01) reasons.push('فرق بين COGS وتكلفة sale_out');
    if (retQty > saleoutQty && saleoutQty > 0) reasons.push('مرتجعات أكبر من المبيعات حركياً');
    if (avgCost <= 0 && cost > 0) reasons.push('avg_cost لا يفسر تكلفة التقرير');

    let priority = 'متوسطة';
    if ((sales > 0 && cost === 0) || (cost > sales * 2) || (sales > 0 && qty <= 0)) priority = 'عالية';

    return {
      item_id: itemId,
      item_name: r.item_name,
      quantity_sold: r2(qty),
      total_sales: r2(sales),
      total_cost: r2(cost),
      total_profit: r2(profit),
      cost_to_sales_pct: sales > 0 ? r2((cost / sales) * 100) : 0,
      diagnostics: {
        cogs_rows: cogsRows,
        cogs_sum: r2(cogsSum),
        saleout_qty: r2(saleoutQty),
        saleout_cost: r2(saleoutCost),
        returnin_qty: r2(retQty),
        avg_cost: r2(avgCost),
      },
      probable_reasons: reasons,
      priority,
    };
  }).sort((a, b) => {
    const p = { 'عالية': 2, 'متوسطة': 1, 'منخفضة': 0 };
    if (p[b.priority] !== p[a.priority]) return p[b.priority] - p[a.priority];
    return (b.total_cost - b.total_sales) - (a.total_cost - a.total_sales);
  });

  const out = {
    period: { start, end },
    anomalies_total: analyzed.length,
    high_priority: analyzed.filter((x) => x.priority === 'عالية').length,
    medium_priority: analyzed.filter((x) => x.priority === 'متوسطة').length,
    items: analyzed,
  };

  const outPath = path.join(process.cwd(), 'product_margin_rootcause_report_after_fix.json');
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
  console.log(outPath);
} finally {
  await client.end();
}
