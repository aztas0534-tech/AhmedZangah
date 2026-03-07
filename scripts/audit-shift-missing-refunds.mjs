import fs from 'fs';
import { Client } from 'pg';

const args = process.argv.slice(2);
const readArg = (name, fallback = '') => {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const v = args[i + 1];
  return typeof v === 'string' ? v : fallback;
};

const limit = Math.max(1, Number(readArg('--limit', '50')) || 50);
const shiftId = readArg('--shift-id', '').trim();
const shiftNumberRaw = readArg('--shift-number', '').trim();
const onlyIssues = !args.includes('--all');
const showReturns = args.includes('--show-returns');

const poolerUrl = (() => {
  try {
    return fs.readFileSync('supabase/.temp/pooler-url', 'utf8').trim();
  } catch {
    return '';
  }
})();

const fallbackHost = 'aws-1-ap-south-1.pooler.supabase.com';
const fallbackUser = 'postgres.pmhivhtaoydfolseelyc';
const fallbackDb = 'postgres';

const parsed = (() => {
  if (!poolerUrl) return null;
  try {
    return new URL(poolerUrl);
  } catch {
    return null;
  }
})();

const host = process.env.DB_HOST || parsed?.hostname || fallbackHost;
const port = Number(process.env.DB_PORT || parsed?.port || 5432);
const user = process.env.DB_USER || decodeURIComponent(parsed?.username || fallbackUser);
const database = process.env.DB_NAME || (parsed?.pathname ? parsed.pathname.replace(/^\//, '') : fallbackDb) || fallbackDb;
const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();

if (!password) {
  console.error('Missing DB password. Set DBPW or SUPABASE_DB_PASSWORD');
  process.exit(1);
}

const shiftNumber = shiftNumberRaw ? Number(shiftNumberRaw) : null;
if (shiftNumberRaw && !Number.isFinite(shiftNumber)) {
  console.error('Invalid --shift-number');
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

const shiftsSql = `
with scoped as (
  select s.id, s.shift_number, s.status, s.cashier_id, s.opened_at, s.closed_at
  from public.cash_shifts s
  where ($1::uuid is null or s.id = $1::uuid)
    and ($2::bigint is null or s.shift_number = $2::bigint)
  order by s.opened_at desc
  limit $3
)
select
  s.id,
  s.shift_number,
  s.status,
  s.cashier_id,
  s.opened_at,
  s.closed_at,
  coalesce(m.missing_count, 0)::int as missing_count,
  coalesce(m.missing_base, 0)::numeric(18,2) as missing_base
from scoped s
left join lateral (
  with miss as (
    select
      sr.id,
      sr.total_refund_amount,
      o.currency,
      o.fx_rate,
      o.base_total,
      o.total
    from public.sales_returns sr
    left join public.orders o on o.id = sr.order_id
    where sr.return_date >= s.opened_at
      and sr.return_date <= coalesce(s.closed_at, now())
      and (s.cashier_id is null or sr.created_by = s.cashier_id)
      and not exists (
        select 1
        from public.payments p
        where p.reference_table = 'sales_returns'
          and p.reference_id = sr.id::text
      )
  )
  select
    count(*)::int as missing_count,
    round(
      coalesce(
        sum(
          case
            when upper(coalesce(currency, '')) = upper(public.get_base_currency()) then coalesce(total_refund_amount, 0)
            else coalesce(total_refund_amount, 0) * coalesce(
              case
                when coalesce(total, 0) > 0 and coalesce(base_total, 0) > 0 then (base_total / total)
                when coalesce(fx_rate, 0) > 0 then fx_rate
                else 1
              end,
              1
            )
          end
        ),
        0
      )::numeric,
      2
    ) as missing_base
  from miss
) m on true
order by s.opened_at desc;
`;

const detailsSql = `
with sh as (
  select *
  from public.cash_shifts
  where id = $1::uuid
)
select
  sr.id,
  sr.return_date,
  sr.total_refund_amount,
  o.currency,
  o.fx_rate,
  o.base_total,
  o.total,
  round(
    (
      case
        when upper(coalesce(o.currency, '')) = upper(public.get_base_currency()) then coalesce(sr.total_refund_amount, 0)
        else coalesce(sr.total_refund_amount, 0) * coalesce(
          case
            when coalesce(o.total, 0) > 0 and coalesce(o.base_total, 0) > 0 then (o.base_total / o.total)
            when coalesce(o.fx_rate, 0) > 0 then o.fx_rate
            else 1
          end,
          1
        )
      end
    )::numeric,
    2
  ) as computed_base
from public.sales_returns sr
left join public.orders o on o.id = sr.order_id
cross join sh
where sr.return_date >= sh.opened_at
  and sr.return_date <= coalesce(sh.closed_at, now())
  and (sh.cashier_id is null or sr.created_by = sh.cashier_id)
  and not exists (
    select 1
    from public.payments p
    where p.reference_table = 'sales_returns'
      and p.reference_id = sr.id::text
  )
order by computed_base desc
limit 30;
`;

const run = async () => {
  await client.connect();
  const rows = (
    await client.query(shiftsSql, [shiftId || null, Number.isFinite(shiftNumber) ? shiftNumber : null, limit])
  ).rows;

  const output = onlyIssues ? rows.filter((r) => Number(r.missing_count) > 0 || Number(r.missing_base) > 0) : rows;
  const mapped = output.map((r) => ({
    shift_id: r.id,
    shift_number: r.shift_number,
    status: r.status,
    opened_at: r.opened_at,
    missing_count: Number(r.missing_count || 0),
    missing_base: Number(r.missing_base || 0),
  }));
  console.table(mapped);

  const totalShifts = rows.length;
  const affected = rows.filter((r) => Number(r.missing_count) > 0 || Number(r.missing_base) > 0);
  const totalMissingBase = affected.reduce((s, r) => s + Number(r.missing_base || 0), 0);
  const totalMissingCount = affected.reduce((s, r) => s + Number(r.missing_count || 0), 0);
  console.log(JSON.stringify({
    scanned_shifts: totalShifts,
    affected_shifts: affected.length,
    total_missing_count: totalMissingCount,
    total_missing_base: Number(totalMissingBase.toFixed(2)),
  }, null, 2));

  if (showReturns && affected.length > 0) {
    const target = shiftId || String(affected[0].id);
    const d = (await client.query(detailsSql, [target])).rows;
    console.log(`details_for_shift=${target}`);
    console.table(d.map((r) => ({
      id: r.id,
      return_date: r.return_date,
      total_refund_amount: Number(r.total_refund_amount || 0),
      currency: r.currency,
      fx_rate: Number(r.fx_rate || 0),
      base_total: Number(r.base_total || 0),
      total: Number(r.total || 0),
      computed_base: Number(r.computed_base || 0),
    })));
  }

  await client.end();
};

run().catch(async (e) => {
  console.error('audit_failed:', e?.message || e);
  try {
    await client.end();
  } catch {}
  process.exit(1);
});
