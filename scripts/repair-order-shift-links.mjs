import fs from 'fs';
import { Client } from 'pg';

const args = process.argv.slice(2);
const hasFlag = (flag) => args.includes(flag);
const readArg = (name, fallback = '') => {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const v = args[i + 1];
  return typeof v === 'string' ? v : fallback;
};

const apply = hasFlag('--apply');
const onlyUnlinked = hasFlag('--only-unlinked');
const limit = Math.max(1, Number(readArg('--limit', '5000')) || 5000);
const orderId = readArg('--order-id', '').trim();
const from = readArg('--from', '').trim();
const to = readArg('--to', '').trim();
const strategy = String(readArg('--strategy', 'actor')).trim().toLowerCase();
const refsRaw = String(readArg('--refs', 'orders')).trim();
const refs = refsRaw
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

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

if (!['actor', 'order-creator'].includes(strategy)) {
  console.error('Invalid --strategy. Use actor or order-creator');
  process.exit(1);
}
if (!refs.length) {
  console.error('Invalid --refs');
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

const baseScopeSql = `
with scoped as (
  select
    p.id as payment_id,
    p.reference_table,
    p.reference_id as order_id_text,
    p.created_by,
    case
      when coalesce(o.data->>'createdBy','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (o.data->>'createdBy')::uuid
      when coalesce(o.data->>'deliveredBy','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (o.data->>'deliveredBy')::uuid
      when coalesce(o.data->>'paymentVerifiedBy','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (o.data->>'paymentVerifiedBy')::uuid
      else null
    end as order_created_by,
    p.occurred_at,
    p.shift_id as current_shift_id
  from public.payments p
  left join public.orders o on p.reference_table = 'orders' and o.id::text = p.reference_id
  where p.reference_table = any($7::text[])
    and p.occurred_at is not null
    and ($1::text is null or p.reference_id = $1::text)
    and ($2::timestamptz is null or p.occurred_at >= $2::timestamptz)
    and ($3::timestamptz is null or p.occurred_at <= $3::timestamptz)
    and (not $4::boolean or p.shift_id is null)
  order by p.occurred_at desc
  limit $5
),
matched as (
  select
    s.*,
    cur.cashier_id as current_cashier_id,
    cur.opened_at as current_opened_at,
    cur.closed_at as current_closed_at,
    (
      s.current_shift_id is not null
      and cur.id is not null
      and s.created_by = cur.cashier_id
      and s.occurred_at >= cur.opened_at
      and s.occurred_at <= coalesce(cur.closed_at, now() + interval '1 day')
    ) as current_valid,
    cand.id as suggested_shift_id,
    cand.cashier_id as suggested_cashier_id,
    cand_order.id as suggested_shift_by_order_creator
  from scoped s
  left join public.cash_shifts cur on cur.id = s.current_shift_id
  left join lateral (
    select cs.id, cs.cashier_id
    from public.cash_shifts cs
    where cs.cashier_id = s.created_by
      and s.occurred_at >= cs.opened_at
      and s.occurred_at <= coalesce(cs.closed_at, now() + interval '1 day')
    order by cs.opened_at desc
    limit 1
  ) cand on true
  left join lateral (
    select cs.id
    from public.cash_shifts cs
    where cs.cashier_id = s.order_created_by
      and s.occurred_at >= cs.opened_at
      and s.occurred_at <= coalesce(cs.closed_at, now() + interval '1 day')
    order by cs.opened_at desc
    limit 1
  ) cand_order on true
),
fixable as (
  select
    m.*,
    case
      when $6::text = 'order-creator' then m.suggested_shift_by_order_creator
      else m.suggested_shift_id
    end as selected_suggested_shift_id,
    case
      when m.current_valid then false
      when (case when $6::text = 'order-creator' then m.suggested_shift_by_order_creator else m.suggested_shift_id end) is null then false
      when m.current_shift_id is null then true
      when m.current_shift_id <> (case when $6::text = 'order-creator' then m.suggested_shift_by_order_creator else m.suggested_shift_id end) then true
      else false
    end as should_fix
  from matched m
)
`;

const previewSql = `
${baseScopeSql}
select
  count(*)::int as scanned,
  count(*) filter (where current_valid)::int as already_valid,
  count(*) filter (where not current_valid and suggested_shift_id is null)::int as unresolved,
  count(*) filter (where should_fix)::int as fixable
from fixable;
`;

const detailsSql = `
${baseScopeSql}
select
  payment_id,
  reference_table,
  order_id_text,
  occurred_at,
  created_by,
  order_created_by,
  current_shift_id,
  suggested_shift_id,
  suggested_shift_by_order_creator,
  selected_suggested_shift_id,
  current_valid,
  should_fix
from fixable
where should_fix or (not current_valid and suggested_shift_id is null)
order by occurred_at desc
limit 200;
`;

const applySql = `
${baseScopeSql},
to_fix as (
  select payment_id, selected_suggested_shift_id as suggested_shift_id
  from fixable
  where should_fix
)
update public.payments p
set shift_id = f.suggested_shift_id
from to_fix f
where p.id = f.payment_id;
`;

const run = async () => {
  await client.connect();

  const params = [
    orderId || null,
    from || null,
    to || null,
    onlyUnlinked,
    limit,
    strategy,
    refs,
  ];

  const preview = (await client.query(previewSql, params)).rows[0];
  console.log('summary_before', JSON.stringify(preview, null, 2));

  const details = (await client.query(detailsSql, params)).rows;
  console.table(
    details.map((r) => ({
      payment_id: r.payment_id,
      reference_table: r.reference_table,
      order_id: r.order_id_text,
      occurred_at: r.occurred_at,
      order_created_by: r.order_created_by,
      current_shift_id: r.current_shift_id,
      suggested_shift_id: r.suggested_shift_id,
      suggested_shift_by_order_creator: r.suggested_shift_by_order_creator,
      selected_suggested_shift_id: r.selected_suggested_shift_id,
      current_valid: r.current_valid,
      should_fix: r.should_fix,
    }))
  );

  if (!apply) {
    console.log(`dry_run=true strategy=${strategy} (pass --apply to execute update)`);
    await client.end();
    return;
  }

  await client.query('begin');
  const upd = await client.query(applySql, params);
  await client.query('commit');
  console.log(`updated_rows=${upd.rowCount}`);

  const after = (await client.query(previewSql, params)).rows[0];
  console.log('summary_after', JSON.stringify(after, null, 2));

  await client.end();
};

run().catch(async (e) => {
  try {
    await client.query('rollback');
  } catch {}
  try {
    await client.end();
  } catch {}
  console.error('repair_failed:', e?.message || e);
  process.exit(1);
});
