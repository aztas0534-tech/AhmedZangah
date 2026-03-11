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
const num = (v) => Number(v || 0);
const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

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

  const rows = (await client.query(
    `select * from public.get_product_sales_report_v9($1::timestamptz,$2::timestamptz,$3::uuid,$4::boolean)`,
    [start, end, null, false]
  )).rows;

  const summary = (await client.query(
    `select public.get_sales_report_summary($1::timestamptz,$2::timestamptz,$3::uuid,$4::boolean) as s`,
    [start, end, null, false]
  )).rows[0]?.s || {};

  const totals = rows.reduce((a, r) => {
    a.sales += num(r.total_sales);
    a.cost += num(r.total_cost);
    a.profit += num(r.total_profit);
    a.qty += num(r.quantity_sold);
    return a;
  }, { sales: 0, cost: 0, profit: 0, qty: 0 });

  const grossSubtotal = num(summary.gross_subtotal);
  const discounts = num(summary.discounts);
  const returns = num(summary.returns);
  const cogs = num(summary.cogs);
  const derivedNetSales = grossSubtotal - discounts - returns;

  const out = {
    period: { start, end },
    totals: {
      items_count: rows.length,
      qty_sold: round2(totals.qty),
      net_sales_sum: round2(totals.sales),
      total_cost_sum: round2(totals.cost),
      total_profit_sum: round2(totals.profit),
      gross_margin_pct: round2(totals.sales > 0 ? (totals.profit / totals.sales) * 100 : 0),
    },
    reconciliation: {
      sales_summary: {
        gross_subtotal: round2(grossSubtotal),
        discounts: round2(discounts),
        returns: round2(returns),
        cogs: round2(cogs),
        derived_net_sales: round2(derivedNetSales),
      },
      product_report: {
        net_sales_sum: round2(totals.sales),
        cost_sum: round2(totals.cost),
      },
      diff: {
        net_sales_diff: round2(totals.sales - derivedNetSales),
        cogs_diff: round2(totals.cost - cogs),
      },
    },
  };

  const outPath = path.join(process.cwd(), 'product_margin_audit_report_after_fix.json');
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
  console.log(outPath);
} finally {
  await client.end();
}
