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

  const items = (await client.query(`
    select id::text as item_id, data->'name' as item_name, unit_type, cost_price
    from public.menu_items
    where coalesce(data->'name'->>'ar','') in (
      'شوكلاته بوكي بار اصابع 12*24*20جم',
      'تونة حلوة كبير *48حبة*160جم',
      'فطائر ياسمين اني *12باكت*40*10جم'
    )
    order by data->'name'->>'ar'
  `)).rows;

  const itemIds = items.map((x) => x.item_id);

  const movement = (await client.query(`
    select
      im.item_id::text as item_id,
      sum(case when im.reference_table='orders' and im.movement_type='sale_out' then im.quantity else 0 end) as sale_out_qty,
      sum(case when im.reference_table='orders' and im.movement_type='sale_out' then im.total_cost else 0 end) as sale_out_cost,
      sum(case when im.reference_table='sales_returns' and im.movement_type='return_in' then im.quantity else 0 end) as return_in_qty,
      sum(case when im.reference_table='sales_returns' and im.movement_type='return_in' then im.total_cost else 0 end) as return_in_cost
    from public.inventory_movements im
    where im.item_id::text = any($1::text[])
    group by im.item_id::text
  `, [itemIds])).rows;

  const report = (await client.query(`
    select item_id::text, item_name, quantity_sold, total_sales, total_cost, total_profit
    from public.get_product_sales_report_v10($1::timestamptz,$2::timestamptz,$3::uuid,$4::boolean)
    where item_id::text = any($5::text[])
    order by item_id::text
  `, ['1970-01-01T00:00:00.000Z', new Date().toISOString(), null, false, itemIds])).rows;

  const oic = (await client.query(`
    select item_id::text, sum(quantity) as oic_qty, sum(total_cost) as oic_cost
    from public.order_item_cogs
    where item_id::text = any($1::text[])
    group by item_id::text
  `, [itemIds])).rows;

  const purchase = (await client.query(`
    select
      im.item_id::text as item_id,
      count(*) as purchase_in_rows,
      min(im.occurred_at) as first_purchase_at,
      max(im.occurred_at) as last_purchase_at,
      max(coalesce(je.currency_code,'')) as sample_currency,
      max(coalesce(je.fx_rate,0)) as sample_fx_rate,
      max(im.unit_cost) as max_purchase_unit_cost,
      min(im.unit_cost) as min_purchase_unit_cost
    from public.inventory_movements im
    left join public.journal_entries je
      on je.source_table='inventory_movements'
     and je.source_id=im.id::text
     and je.source_event='purchase_in'
    where im.item_id::text = any($1::text[])
      and im.movement_type='purchase_in'
    group by im.item_id::text
  `, [itemIds])).rows;

  const out = {
    generated_at: new Date().toISOString(),
    items,
    report,
    movement,
    oic,
    purchase,
  };

  const outPath = path.join(process.cwd(), 'two_cases_diagnose_prod.json');
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
  console.log(outPath);
} finally {
  await client.end();
}
