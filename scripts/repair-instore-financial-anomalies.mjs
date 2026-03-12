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
const days = Math.max(1, Number(readArg('--days', '120')) || 120);
const limit = Math.max(1, Number(readArg('--limit', '200')) || 200);
const modeRaw = String(readArg('--mode', 'all')).trim().toLowerCase();
const mode = modeRaw === 'orders' || modeRaw === 'returns' ? modeRaw : 'all';

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

const UUID_RX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const parseUuid = (v) => {
  const s = String(v || '').trim();
  return UUID_RX.test(s) ? s : null;
};
const normalizeMethod = (raw) => {
  const m = String(raw || '').trim().toLowerCase();
  if (!m) return 'cash';
  if (m === 'card' || m === 'online') return 'network';
  if (m === 'bank' || m === 'bank_transfer') return 'kuraimi';
  return m;
};
const qNum = (n, dp = 6) => {
  const x = Number(n || 0);
  if (!Number.isFinite(x)) return 0;
  const p = Math.pow(10, dp);
  return Math.round(x * p) / p;
};

const qOrderCandidates = `
with scoped as (
  select
    o.id,
    o.created_at,
    o.updated_at,
    o.status,
    o.data,
    coalesce(nullif(o.data->>'orderSource',''), '') as order_source
  from public.orders o
  where o.created_at >= (now() - ($1::int || ' days')::interval)
    and coalesce(nullif(o.data->>'orderSource',''), '') = 'in_store'
)
select
  s.id as order_id,
  s.created_at,
  s.updated_at,
  coalesce(nullif(s.data->>'paymentMethod',''), '') as payment_method,
  lower(coalesce(nullif(s.data->>'invoiceTerms',''), '')) as invoice_terms,
  lower(coalesce(nullif(s.data->>'isCreditSale',''), '')) as is_credit_sale,
  coalesce(nullif(s.data->>'currency',''), public.get_base_currency()) as currency,
  coalesce(nullif((s.data->>'fxRate')::numeric, null), 1) as fx_rate,
  coalesce(nullif((s.data->>'total')::numeric, null), 0) as amount_foreign,
  coalesce(nullif((s.data->>'baseTotal')::numeric, null), coalesce(nullif((s.data->>'total')::numeric, null), 0) * coalesce(nullif((s.data->>'fxRate')::numeric, null), 1), 0) as amount_base,
  coalesce(
    case when coalesce(nullif(s.data->>'deliveredAt',''),'') <> '' then (s.data->>'deliveredAt')::timestamptz else null end,
    s.updated_at,
    s.created_at
  ) as occurred_at,
  coalesce(nullif(s.data->>'deliveredBy',''), nullif(s.data->>'createdBy','')) as actor_text
from scoped s
where s.status = 'delivered'
  and coalesce(nullif(trim(coalesce(s.data->>'voidedAt','')), ''), '') = ''
  and lower(coalesce(nullif(s.data->>'paymentMethod',''), '')) in ('cash','network','kuraimi','bank','bank_transfer','card','online')
  and lower(coalesce(nullif(s.data->>'paymentMethod',''), '')) <> 'ar'
  and lower(coalesce(nullif(s.data->>'invoiceTerms',''), '')) <> 'credit'
  and lower(coalesce(nullif(s.data->>'isCreditSale',''), '')) <> 'true'
  and not exists (
    select 1
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = s.id::text
      and p.direction = 'in'
  )
order by s.created_at desc
limit $2;
`;

const qReturnCandidates = `
with scoped as (
  select
    sr.id as return_id,
    sr.order_id,
    sr.status,
    sr.return_date,
    sr.refund_method,
    sr.total_refund_amount,
    o.data as order_data
  from public.sales_returns sr
  join public.orders o on o.id = sr.order_id
  where sr.return_date >= (now() - ($1::int || ' days')::interval)
    and coalesce(nullif(o.data->>'orderSource',''), '') = 'in_store'
    and sr.status = 'completed'
)
select
  s.return_id,
  s.order_id,
  s.return_date,
  s.refund_method,
  coalesce(nullif(s.order_data->>'currency',''), public.get_base_currency()) as currency,
  coalesce(nullif((s.order_data->>'fxRate')::numeric, null), 1) as fx_rate,
  coalesce(
    (
      select max(jl.foreign_amount)
      from public.journal_entries je
      join public.journal_lines jl on jl.journal_entry_id = je.id
      where je.source_table = 'sales_returns'
        and je.source_id = s.return_id::text
        and je.source_event = 'processed'
        and coalesce(jl.foreign_amount, 0) > 0
    ),
    s.total_refund_amount,
    0
  ) as amount_foreign,
  coalesce(
    (
      select max(jl.credit)
      from public.journal_entries je
      join public.journal_lines jl on jl.journal_entry_id = je.id
      where je.source_table = 'sales_returns'
        and je.source_id = s.return_id::text
        and je.source_event = 'processed'
        and coalesce(jl.credit, 0) > 0
    ),
    case
      when upper(coalesce(nullif(s.order_data->>'currency',''), public.get_base_currency())) = upper(public.get_base_currency()) then coalesce(s.total_refund_amount, 0)
      else coalesce(s.total_refund_amount, 0) * coalesce(nullif((s.order_data->>'fxRate')::numeric, null), 1)
    end
  ) as amount_base,
  (
    select p.shift_id
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = s.order_id::text
      and p.shift_id is not null
    order by p.occurred_at desc
    limit 1
  ) as fallback_shift_id
from scoped s
where not exists (
  select 1
  from public.payments p
  where p.reference_table = 'sales_returns'
    and p.reference_id = s.return_id::text
    and p.direction = 'out'
)
order by s.return_date desc
limit $2;
`;

const resolveCashShift = async (actorUuid, occurredAt) => {
  if (!occurredAt) return null;
  if (actorUuid) {
    const q = await client.query(
      `select cs.id
       from public.cash_shifts cs
       where cs.cashier_id = $1::uuid
         and $2::timestamptz >= cs.opened_at
         and $2::timestamptz <= coalesce(cs.closed_at, now() + interval '1 day')
       order by cs.opened_at desc
       limit 1`,
      [actorUuid, occurredAt]
    );
    if (q.rows[0]?.id) return q.rows[0].id;
  }
  const fallback = await client.query(
    `select cs.id
     from public.cash_shifts cs
     where $1::timestamptz >= cs.opened_at
       and $1::timestamptz <= coalesce(cs.closed_at, now() + interval '1 day')
     order by cs.opened_at desc
     limit 1`,
    [occurredAt]
  );
  return fallback.rows[0]?.id || null;
};

const run = async () => {
  await client.connect();
  const actorSeed = (await client.query(
    `select cs.cashier_id::text as id
     from public.cash_shifts cs
     where cs.cashier_id is not null
     order by cs.opened_at desc
     limit 1`
  )).rows[0]?.id || null;
  const serviceActor = parseUuid(actorSeed);
  const p = [days, limit];
  const destinationCache = new Map();
  const resolveDestinationAccountId = async (method, currency) => {
    const normalizedMethod = normalizeMethod(method);
    if (normalizedMethod !== 'network' && normalizedMethod !== 'kuraimi') return null;
    const curr = String(currency || '').trim().toUpperCase() || 'YER';
    const cacheKey = `${normalizedMethod}|${curr}`;
    if (destinationCache.has(cacheKey)) return destinationCache.get(cacheKey);
    const parentCode = normalizedMethod === 'kuraimi' ? '1020' : '1030';
    const row = (await client.query(
      `select c.id::text as id
       from public.chart_of_accounts c
       join public.chart_of_accounts p on p.id = c.parent_id
       where c.is_active = true
         and p.code = $1
         and upper(coalesce(substring(c.code from '([A-Za-z]{3})$'), '')) = $2
       order by c.created_at asc
       limit 1`,
      [parentCode, curr]
    )).rows[0];
    const resolved = row?.id ? String(row.id) : null;
    destinationCache.set(cacheKey, resolved);
    return resolved;
  };

  const orderCandidates = mode === 'returns' ? [] : (await client.query(qOrderCandidates, p)).rows;
  const returnCandidatesRaw = mode === 'orders' ? [] : (await client.query(qReturnCandidates, p)).rows;

  const returnCandidates = returnCandidatesRaw
    .map((r) => {
      const method = normalizeMethod(r.refund_method);
      const expectedPayment = method === 'cash' || method === 'network' || method === 'kuraimi';
      return { ...r, normalized_method: method, expected_payment: expectedPayment };
    })
    .filter((r) => r.expected_payment);

  console.log(JSON.stringify({
    dry_run: !apply,
    mode,
    found_orders_missing_in_payment: orderCandidates.length,
    found_returns_missing_out_payment: returnCandidates.length,
  }, null, 2));

  if (orderCandidates.length) {
    console.table(orderCandidates.map((r) => ({
      order_id: r.order_id,
      method: normalizeMethod(r.payment_method),
      currency: r.currency,
      amount_foreign: qNum(r.amount_foreign, 4),
      amount_base: qNum(r.amount_base, 4),
      occurred_at: r.occurred_at,
      actor: r.actor_text,
    })));
  }

  if (returnCandidates.length) {
    console.table(returnCandidates.map((r) => ({
      return_id: r.return_id,
      order_id: r.order_id,
      method: r.normalized_method,
      currency: r.currency,
      amount_foreign: qNum(r.amount_foreign, 4),
      amount_base: qNum(r.amount_base, 4),
      return_date: r.return_date,
      fallback_shift_id: r.fallback_shift_id,
    })));
  }

  if (!apply) {
    await client.end();
    return;
  }

  let ordersUpdated = 0;
  let returnsUpdated = 0;
  let skippedCashOrdersNoShift = 0;
  let skippedCashReturnsNoShift = 0;
  let skippedNetworkOrdersNoDestination = 0;
  const skippedOrderIds = [];
  const skippedReturnIds = [];

  await client.query('begin');
  try {
    if (serviceActor) {
      await client.query(`select set_config('request.jwt.claim.role', 'service_role', true)`);
      await client.query(`select set_config('request.jwt.claim.sub', $1::text, true)`, [serviceActor]);
    }
    for (const row of orderCandidates) {
      const method = normalizeMethod(row.payment_method);
      if (!['cash', 'network', 'kuraimi', 'ar', 'store_credit'].includes(method)) continue;
      const currency = String(row.currency || '').trim().toUpperCase() || 'YER';
      const fxRate = qNum(row.fx_rate || 1, 10) || 1;
      const amountForeign = qNum(row.amount_foreign, 6);
      const amountBase = qNum(row.amount_base, 6);
      if (!(amountForeign > 0) || !(amountBase > 0)) continue;
      const occurredAt = row.occurred_at || row.updated_at || row.created_at || new Date().toISOString();
      const actor = parseUuid(row.actor_text);
      let shiftId = null;
      if (method === 'cash') {
        shiftId = await resolveCashShift(actor, occurredAt);
        if (!shiftId) {
          skippedCashOrdersNoShift += 1;
          skippedOrderIds.push(row.order_id);
          continue;
        }
      }
      const destinationAccountId = await resolveDestinationAccountId(method, currency);
      if ((method === 'network' || method === 'kuraimi') && !destinationAccountId) {
        skippedNetworkOrdersNoDestination += 1;
        skippedOrderIds.push(row.order_id);
        continue;
      }
      const idempotencyKey = `repair:instore:order:${row.order_id}:missing_in:v1`;
      await client.query(
        `insert into public.payments(
          direction, method, amount, currency, fx_rate, base_amount,
          reference_table, reference_id, occurred_at, created_by, data, idempotency_key, shift_id
        )
        values (
          'in', $1, $2, $3, $4, $5,
          'orders', $6::text, $7, coalesce($8::uuid, $12::uuid), jsonb_strip_nulls(jsonb_build_object('orderId',$6::text,'repair','missing_order_payment_v1','destinationAccountId',$11::text)), $9, $10::uuid
        )
        on conflict (reference_table, reference_id, direction, idempotency_key)
        do update set
          method = excluded.method,
          amount = excluded.amount,
          currency = excluded.currency,
          fx_rate = excluded.fx_rate,
          base_amount = excluded.base_amount,
          occurred_at = excluded.occurred_at,
          shift_id = excluded.shift_id`,
        [method, amountForeign, currency, fxRate, amountBase, row.order_id, occurredAt, actor, idempotencyKey, shiftId, destinationAccountId, serviceActor]
      );
      ordersUpdated += 1;
    }

    for (const row of returnCandidates) {
      const method = row.normalized_method;
      const currency = String(row.currency || '').trim().toUpperCase() || 'YER';
      const fxRate = qNum(row.fx_rate || 1, 10) || 1;
      const amountForeign = qNum(row.amount_foreign, 6);
      const amountBase = qNum(row.amount_base, 6);
      if (!(amountForeign > 0) || !(amountBase > 0)) continue;
      const occurredAt = row.return_date || new Date().toISOString();
      const shiftId = method === 'cash' ? (row.fallback_shift_id || null) : null;
      if (method === 'cash' && !shiftId) {
        skippedCashReturnsNoShift += 1;
        skippedReturnIds.push(row.return_id);
        continue;
      }
      const idempotencyKey = `repair:instore:return:${row.return_id}:missing_out:v1`;
      await client.query(
        `insert into public.payments(
          direction, method, amount, currency, fx_rate, base_amount,
          reference_table, reference_id, occurred_at, created_by, data, idempotency_key, shift_id
        )
        values (
          'out', $1, $2, $3, $4, $5,
          'sales_returns', $6::text, $7, $11::uuid, jsonb_build_object('salesReturnId',$6::text,'orderId',$8::text,'repair','missing_return_payment_v1'), $9, $10::uuid
        )
        on conflict (reference_table, reference_id, direction, idempotency_key)
        do update set
          method = excluded.method,
          amount = excluded.amount,
          currency = excluded.currency,
          fx_rate = excluded.fx_rate,
          base_amount = excluded.base_amount,
          occurred_at = excluded.occurred_at,
          shift_id = excluded.shift_id`,
        [method, amountForeign, currency, fxRate, amountBase, row.return_id, occurredAt, row.order_id, idempotencyKey, shiftId, serviceActor]
      );
      returnsUpdated += 1;
    }

    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  }

  console.log(JSON.stringify({
    applied: true,
    orders_updated: ordersUpdated,
    returns_updated: returnsUpdated,
    skipped_cash_orders_no_shift: skippedCashOrdersNoShift,
    skipped_cash_returns_no_shift: skippedCashReturnsNoShift,
    skipped_network_orders_no_destination: skippedNetworkOrdersNoDestination,
    skipped_order_ids: skippedOrderIds,
    skipped_return_ids: skippedReturnIds,
  }, null, 2));

  await client.end();
};

run().catch(async (e) => {
  try {
    await client.end();
  } catch {}
  console.error('repair_failed:', e?.message || e);
  process.exit(1);
});
