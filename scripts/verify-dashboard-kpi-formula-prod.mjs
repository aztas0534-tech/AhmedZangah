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
  const { rows } = await client.query("select public.get_dashboard_kpi_v4(now()-interval '30 days', now(), null, false, null) as k");
  const sales = rows?.[0]?.k?.sales || {};
  const netSales = Number(sales.total_sales_accrual || 0) - Number(sales.returns_total ?? sales.returns || 0);
  const cogs = Math.max(0, Number(sales.cogs || 0));
  const grossProfit = netSales - cogs;
  const margin = netSales > 0 ? (grossProfit / netSales) * 100 : 0;
  console.log(JSON.stringify({ netSales, cogs, grossProfit, margin }, null, 2));
} finally {
  await client.end();
}
