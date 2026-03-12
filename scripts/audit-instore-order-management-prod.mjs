import fs from 'fs';
import { Client } from 'pg';
import path from 'path';
import { fileURLToPath } from 'url';

const args = process.argv.slice(2);
const readArg = (name, fallback = '') => {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const v = args[i + 1];
  return typeof v === 'string' ? v : fallback;
};
const days = Math.max(1, Number(readArg('--days', '90')) || 90);
const limit = Math.max(1, Number(readArg('--limit', '30')) || 30);

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
    o.warehouse_id::text as warehouse_id,
    coalesce(nullif(o.data->>'orderSource',''), '') as order_source,
    coalesce(
      nullif((o.data->>'baseTotal')::numeric, null),
      coalesce(nullif((o.data->>'total')::numeric, null), 0) * coalesce(nullif((o.data->>'fxRate')::numeric, null), 1),
      0
    ) as base_total,
    coalesce(nullif((o.data->>'total')::numeric, null), 0) as total_foreign,
    coalesce(nullif(o.data->>'currency',''), public.get_base_currency()) as currency,
    coalesce(nullif(o.data->>'paymentMethod',''), '') as payment_method,
    nullif(o.data->>'voidedAt','') as voided_at,
    case when coalesce(nullif(o.data->>'paidAt',''),'') <> '' then (o.data->>'paidAt')::timestamptz else null end as paid_at,
    case when coalesce(nullif(o.data->>'deliveredAt',''),'') <> '' then (o.data->>'deliveredAt')::timestamptz else null end as delivered_at,
    nullif(o.data->>'inStoreFailureReason','') as instore_failure_reason
  from public.orders o
  where coalesce(nullif(o.data->>'orderSource',''), '') = 'in_store'
    and o.created_at >= (now() - ($1::int || ' days')::interval)
),
pay as (
  select
    p.reference_id as order_id_text,
    sum(case when p.direction='in' then coalesce(p.base_amount, case when upper(coalesce(p.currency,''))=upper(public.get_base_currency()) then p.amount else 0 end, 0) else 0 end) as in_base,
    sum(case when p.direction='out' then coalesce(p.base_amount, case when upper(coalesce(p.currency,''))=upper(public.get_base_currency()) then p.amount else 0 end, 0) else 0 end) as out_base,
    count(*) filter (where p.direction='in') as in_count,
    count(*) filter (where p.direction='out') as out_count,
    count(*) filter (where p.method='cash' and p.shift_id is null) as cash_without_shift_count
  from public.payments p
  where p.reference_table = 'orders'
  group by p.reference_id
)
`;

const qOverview = `
${scopeCte}
select
  count(*)::int as total_orders,
  count(*) filter (where status='delivered')::int as delivered_orders,
  count(*) filter (where status='pending')::int as pending_orders,
  count(*) filter (where status='cancelled')::int as cancelled_orders,
  count(*) filter (where status='out_for_delivery')::int as out_for_delivery_orders,
  count(*) filter (where status='preparing')::int as preparing_orders,
  count(*) filter (where instore_failure_reason is not null)::int as pending_with_failure_reason,
  coalesce(round(sum(base_total)::numeric,2),0)::numeric(18,2) as total_base_amount
from scoped_orders;
`;

const qFailureReasons = `
${scopeCte}
select
  instore_failure_reason,
  count(*)::int as orders_count
from scoped_orders
where instore_failure_reason is not null
group by instore_failure_reason
order by orders_count desc
limit $2;
`;

const qDeliveryAnomalies = `
${scopeCte}
select
  so.id,
  so.warehouse_id,
  so.status,
  so.created_at,
  so.base_total,
  so.payment_method,
  coalesce(pay.in_base, 0)::numeric(18,2) as in_base,
  coalesce(pay.out_base, 0)::numeric(18,2) as out_base,
  coalesce(pay.in_count, 0)::int as in_count,
  coalesce(pay.out_count, 0)::int as out_count
from scoped_orders so
left join pay on pay.order_id_text = so.id::text
where so.status = 'delivered'
  and coalesce(so.voided_at, '') = ''
  and (
    (so.payment_method in ('cash','network','kuraimi','bank','bank_transfer','card','online') and coalesce(pay.in_count,0) = 0)
    or (so.paid_at is not null and coalesce(pay.in_count,0) = 0)
  )
order by so.created_at desc
limit $2;
`;

const qCancellationAnomalies = `
${scopeCte}
select
  so.id,
  so.created_at,
  coalesce(pay.in_base, 0)::numeric(18,2) as in_base,
  coalesce(pay.out_base, 0)::numeric(18,2) as out_base,
  round((coalesce(pay.in_base,0) - coalesce(pay.out_base,0))::numeric, 2) as unreversed_base
from scoped_orders so
left join pay on pay.order_id_text = so.id::text
where so.status = 'cancelled'
  and coalesce(pay.in_base,0) > 0
  and (coalesce(pay.in_base,0) - coalesce(pay.out_base,0)) > 0.01
order by unreversed_base desc, so.created_at desc
limit $2;
`;

const qShiftAnomalies = `
${scopeCte}
select
  count(*)::int as payments_cash_without_shift
from public.payments p
join scoped_orders so on so.id::text = p.reference_id
where p.reference_table = 'orders'
  and p.method = 'cash'
  and p.shift_id is null;
`;

const qReturnAnomalies = `
with scoped_orders as (
  select o.id, o.created_at
  from public.orders o
  where coalesce(nullif(o.data->>'orderSource',''), '') = 'in_store'
    and o.created_at >= (now() - ($1::int || ' days')::interval)
),
ret as (
  select
    sr.id,
    sr.order_id,
    sr.status,
    sr.return_date,
    coalesce(sr.total_refund_amount,0) as refund_amount,
    case
      when lower(coalesce(sr.refund_method,'')) in ('card','online','network') then 'network'
      when lower(coalesce(sr.refund_method,'')) in ('bank','bank_transfer','kuraimi') then 'kuraimi'
      else lower(coalesce(sr.refund_method,'cash'))
    end as refund_method_norm
  from public.sales_returns sr
  join scoped_orders so on so.id = sr.order_id
  where sr.status = 'completed'
),
pay as (
  select p.reference_id, count(*) as pay_count
  from public.payments p
  where p.reference_table = 'sales_returns'
  group by p.reference_id
)
select
  count(*)::int as completed_returns,
  count(*) filter (where ret.refund_method_norm in ('cash','network','kuraimi') and coalesce(pay.pay_count,0)=0)::int as completed_returns_without_payment,
  coalesce(round(sum(case when ret.refund_method_norm in ('cash','network','kuraimi') and coalesce(pay.pay_count,0)=0 then ret.refund_amount else 0 end)::numeric,2),0)::numeric(18,2) as missing_refund_amount
from ret
left join pay on pay.reference_id = ret.id::text;
`;

const qSampleRecent = `
${scopeCte}
select
  so.id,
  so.warehouse_id,
  so.status,
  so.currency,
  so.total_foreign,
  so.base_total,
  so.payment_method,
  so.created_at,
  so.instore_failure_reason,
  coalesce(pay.in_count,0)::int as in_payments,
  coalesce(pay.out_count,0)::int as out_payments
from scoped_orders so
left join pay on pay.order_id_text = so.id::text
order by so.created_at desc
limit $2;
`;

const run = async () => {
  await client.connect();
  const p1 = [days];
  const p2 = [days, limit];

  const overview = (await client.query(qOverview, p1)).rows[0];
  const failureReasons = (await client.query(qFailureReasons, p2)).rows;
  const deliveryAnomalies = (await client.query(qDeliveryAnomalies, p2)).rows;
  const cancellationAnomalies = (await client.query(qCancellationAnomalies, p2)).rows;
  const shiftAnomalies = (await client.query(qShiftAnomalies, p1)).rows[0];
  const returnAnomalies = (await client.query(qReturnAnomalies, p1)).rows[0];
  const sampleRecent = (await client.query(qSampleRecent, p2)).rows;

  console.log('overview');
  console.log(JSON.stringify(overview, null, 2));
  console.log('failure_reasons');
  console.table(failureReasons);
  console.log('delivery_anomalies');
  console.table(deliveryAnomalies);
  console.log('cancellation_anomalies');
  console.table(cancellationAnomalies);
  console.log('shift_anomalies');
  console.log(JSON.stringify(shiftAnomalies, null, 2));
  console.log('return_anomalies');
  console.log(JSON.stringify(returnAnomalies, null, 2));
  console.log('sample_recent');
  console.table(sampleRecent);
  const payload = {
    generated_at: new Date().toISOString(),
    lookback_days: days,
    limit,
    overview,
    failure_reasons: failureReasons,
    delivery_anomalies: deliveryAnomalies,
    cancellation_anomalies: cancellationAnomalies,
    shift_anomalies: shiftAnomalies,
    return_anomalies: returnAnomalies,
    sample_recent: sampleRecent,
  };
  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  const outDir = path.resolve(__dirname, '..', 'backups');
  fs.mkdirSync(outDir, { recursive: true });
  const stamp = payload.generated_at.replace(/[:.]/g, '-');
  const latestPath = path.join(outDir, 'audit_instore_order_management_prod_latest.json');
  const datedPath = path.join(outDir, `audit_instore_order_management_prod_${stamp}.json`);
  fs.writeFileSync(latestPath, JSON.stringify(payload, null, 2));
  fs.writeFileSync(datedPath, JSON.stringify(payload, null, 2));
  console.log('saved_reports');
  console.log(JSON.stringify({ latestPath, datedPath }, null, 2));

  await client.end();
};

run().catch(async (e) => {
  try { await client.end(); } catch {}
  console.error('audit_failed:', e?.message || e);
  process.exit(1);
});
