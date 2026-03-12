import fs from 'fs';
import { Client } from 'pg';

const args = process.argv.slice(2);
const readArg = (name, fallback = '') => {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const v = args[i + 1];
  return typeof v === 'string' ? v : fallback;
};

const days = Math.max(1, Number(readArg('--days', '30')) || 30);
const limit = Math.max(1, Number(readArg('--limit', '20')) || 20);

const poolerUrl = (() => {
  try {
    return fs.readFileSync('supabase/.temp/pooler-url', 'utf8').trim();
  } catch {
    return '';
  }
})();
const parsed = (() => {
  if (!poolerUrl) return null;
  try {
    return new URL(poolerUrl);
  } catch {
    return null;
  }
})();

const host = process.env.DB_HOST || parsed?.hostname || 'aws-1-ap-south-1.pooler.supabase.com';
const port = Number(process.env.DB_PORT || parsed?.port || 5432);
const user = process.env.DB_USER || decodeURIComponent(parsed?.username || 'postgres.pmhivhtaoydfolseelyc');
const database = process.env.DB_NAME || (parsed?.pathname ? parsed.pathname.replace(/^\//, '') : 'postgres') || 'postgres';
const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) {
  console.error('Missing DB password. Set DBPW or SUPABASE_DB_PASSWORD');
  process.exit(1);
}

const client = new Client({
  host,
  port,
  user,
  password,
  database,
  ssl: { rejectUnauthorized: false },
});

const scopeCte = `
with scoped_orders as (
  select
    o.id,
    o.status,
    o.created_at,
    o.updated_at,
    coalesce(nullif(o.data->>'orderSource',''), '') as order_source,
    coalesce(nullif(o.data->>'paymentMethod',''), '') as payment_method,
    lower(coalesce(nullif(o.data->>'invoiceTerms',''), '')) as invoice_terms,
    lower(coalesce(nullif(o.data->>'isCreditSale',''), '')) as is_credit_sale,
    nullif(o.data->>'voidedAt','') as voided_at,
    case when coalesce(nullif(o.data->>'deliveredAt',''),'') <> '' then (o.data->>'deliveredAt')::timestamptz else null end as delivered_at,
    case when coalesce(nullif(o.data->>'paidAt',''),'') <> '' then (o.data->>'paidAt')::timestamptz else null end as paid_at
  from public.orders o
  where coalesce(nullif(o.data->>'orderSource',''), '') = 'in_store'
    and o.created_at >= (now() - ($1::int || ' days')::interval)
),
pay as (
  select
    p.reference_table,
    p.reference_id,
    count(*) filter (where p.direction='in') as in_count,
    count(*) filter (where p.direction='out') as out_count,
    sum(case when p.direction='in' then coalesce(p.base_amount,0) else 0 end) as in_base,
    sum(case when p.direction='out' then coalesce(p.base_amount,0) else 0 end) as out_base
  from public.payments p
  where p.reference_table in ('orders','sales_returns')
  group by p.reference_table, p.reference_id
),
mv as (
  select
    im.reference_table,
    im.reference_id,
    count(*) filter (where im.movement_type='sale_out') as sale_out_count,
    count(*) filter (where im.movement_type='return_in') as return_in_count,
    count(*) filter (where im.movement_type='return_in' and coalesce(im.data->>'event','')='voided') as return_in_voided_count
  from public.inventory_movements im
  where im.reference_table in ('orders','sales_returns')
  group by im.reference_table, im.reference_id
),
ret as (
  select
    sr.id,
    sr.order_id,
    sr.status,
    sr.return_date,
    lower(coalesce(sr.refund_method,'')) as refund_method,
    coalesce(sr.total_refund_amount,0) as refund_amount
  from public.sales_returns sr
  join scoped_orders so on so.id = sr.order_id
)
`;

const qSummary = `
${scopeCte}
select json_build_object(
  'orders_total', (select count(*)::int from scoped_orders),
  'orders_delivered', (select count(*)::int from scoped_orders where status='delivered'),
  'orders_cancelled', (select count(*)::int from scoped_orders where status='cancelled'),
  'delivered_missing_sale_out', (
    select count(*)::int
    from scoped_orders so
    left join mv on mv.reference_table='orders' and mv.reference_id=so.id::text
    where so.status='delivered'
      and coalesce(so.voided_at,'')=''
      and coalesce(mv.sale_out_count,0)=0
  ),
  'delivered_missing_in_payment', (
    select count(*)::int
    from scoped_orders so
    left join pay on pay.reference_table='orders' and pay.reference_id=so.id::text
    where so.status='delivered'
      and coalesce(so.voided_at,'')=''
      and so.payment_method <> 'ar'
      and so.invoice_terms <> 'credit'
      and so.is_credit_sale <> 'true'
      and (
        so.payment_method in ('cash','network','kuraimi','bank','bank_transfer','card','online')
        or so.paid_at is not null
      )
      and coalesce(pay.in_count,0)=0
  ),
  'cancelled_unreversed_cashflow', (
    select count(*)::int
    from scoped_orders so
    left join pay on pay.reference_table='orders' and pay.reference_id=so.id::text
    where so.status='cancelled'
      and coalesce(pay.in_base,0) - coalesce(pay.out_base,0) > 0.01
  ),
  'voided_orders_missing_stock_reverse', (
    select count(*)::int
    from scoped_orders so
    left join mv on mv.reference_table='orders' and mv.reference_id=so.id::text
    where coalesce(so.voided_at,'') <> ''
      and coalesce(mv.sale_out_count,0) > 0
      and coalesce(mv.return_in_voided_count,0)=0
  ),
  'voided_orders_unreversed_cashflow', (
    select count(*)::int
    from scoped_orders so
    left join pay on pay.reference_table='orders' and pay.reference_id=so.id::text
    where coalesce(so.voided_at,'') <> ''
      and coalesce(pay.in_base,0) - coalesce(pay.out_base,0) > 0.01
  ),
  'returns_completed', (
    select count(*)::int from ret where status='completed'
  ),
  'returns_completed_missing_return_in', (
    select count(*)::int
    from ret r
    left join mv on mv.reference_table='sales_returns' and mv.reference_id=r.id::text
    where r.status='completed'
      and coalesce(mv.return_in_count,0)=0
  ),
  'returns_completed_missing_refund_payment', (
    select count(*)::int
    from ret r
    left join pay on pay.reference_table='sales_returns' and pay.reference_id=r.id::text
    where r.status='completed'
      and r.refund_method in ('cash','card','online','network','bank','bank_transfer','kuraimi')
      and coalesce(pay.out_count,0)=0
  )
) as summary
`;

const qSamples = `
${scopeCte}
select
  so.id,
  so.status,
  so.created_at,
  so.payment_method,
  so.voided_at,
  coalesce(pay.in_count,0)::int as in_payments,
  coalesce(pay.out_count,0)::int as out_payments,
  coalesce(mv.sale_out_count,0)::int as sale_out_count,
  coalesce(mv.return_in_voided_count,0)::int as return_in_voided_count
from scoped_orders so
left join pay on pay.reference_table='orders' and pay.reference_id=so.id::text
left join mv on mv.reference_table='orders' and mv.reference_id=so.id::text
where
  (so.status='delivered' and coalesce(so.voided_at,'')='' and (
    coalesce(mv.sale_out_count,0)=0
    or (
      so.payment_method <> 'ar'
      and so.invoice_terms <> 'credit'
      and so.is_credit_sale <> 'true'
      and (so.payment_method in ('cash','network','kuraimi','bank','bank_transfer','card','online') or so.paid_at is not null)
      and coalesce(pay.in_count,0)=0
    )
  ))
  or (so.status='cancelled' and (coalesce(pay.in_base,0)-coalesce(pay.out_base,0)) > 0.01)
  or (coalesce(so.voided_at,'')<>'' and (coalesce(mv.return_in_voided_count,0)=0 or (coalesce(pay.in_base,0)-coalesce(pay.out_base,0)) > 0.01))
order by so.created_at desc
limit $2
`;

const qReturnsSamples = `
${scopeCte}
select
  r.id as sales_return_id,
  r.order_id,
  r.status,
  r.return_date,
  r.refund_method,
  r.refund_amount,
  coalesce(pay.out_count,0)::int as out_payments,
  coalesce(mv.return_in_count,0)::int as return_in_count
from ret r
left join pay on pay.reference_table='sales_returns' and pay.reference_id=r.id::text
left join mv on mv.reference_table='sales_returns' and mv.reference_id=r.id::text
where r.status='completed'
  and (
    coalesce(mv.return_in_count,0)=0
    or (r.refund_method in ('cash','card','online','network','bank','bank_transfer','kuraimi') and coalesce(pay.out_count,0)=0)
  )
order by r.return_date desc nulls last
limit $2
`;

const run = async () => {
  await client.connect();
  const p1 = [days];
  const p2 = [days, limit];
  const summary = (await client.query(qSummary, p1)).rows[0]?.summary || {};
  const orderSamples = (await client.query(qSamples, p2)).rows;
  const returnSamples = (await client.query(qReturnsSamples, p2)).rows;
  console.log('order_management_lifecycle_summary');
  console.log(JSON.stringify(summary, null, 2));
  console.log('order_anomaly_samples');
  console.table(orderSamples);
  console.log('return_anomaly_samples');
  console.table(returnSamples);
  await client.end();
};

run().catch(async (e) => {
  try { await client.end(); } catch {}
  console.error('smoke_order_lifecycle_failed:', e?.message || e);
  process.exit(1);
});
