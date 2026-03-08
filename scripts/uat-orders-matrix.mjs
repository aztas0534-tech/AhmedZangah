import fs from 'fs';
import path from 'path';
import { Client } from 'pg';

const password = String(process.env.DBPW || '').trim();
if (!password) throw new Error('DBPW is required');

const lookbackDays = Number(process.env.UAT_LOOKBACK_DAYS || 45);

const client = new Client({
  host: 'aws-1-ap-south-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
});

const now = new Date();
const since = new Date(now.getTime() - lookbackDays * 24 * 60 * 60 * 1000);

const toMapCount = (rows, keyField, valField) => {
  const m = new Map();
  for (const r of rows || []) m.set(String(r[keyField]), Number(r[valField]) || 0);
  return m;
};

const getOrderData = (o) => {
  const d = o.data && typeof o.data === 'object' ? o.data : {};
  return d;
};

const getPaymentMethod = (o) => {
  const d = getOrderData(o);
  return String(o.payment_method || d.paymentMethod || '').toLowerCase().trim();
};

const getInvoiceTerms = (o) => {
  const d = getOrderData(o);
  return String(d.invoiceTerms || '').toLowerCase().trim();
};

const getOrderSource = (o) => {
  const d = getOrderData(o);
  return String(d.orderSource || '').toLowerCase().trim();
};

const hasNonBaseUom = (o) => {
  const d = getOrderData(o);
  const items = Array.isArray(d.items) ? d.items : [];
  return items.some((it) => {
    const f = Number(it?.uomQtyInBase ?? it?.uom_qty_in_base ?? 1);
    const code = String(it?.uomCode || it?.uom_code || '').toLowerCase();
    return Math.abs(f - 1) > 1e-9 || ['carton', 'pack', 'box', 'case'].includes(code);
  });
};

await client.connect();

const baseCurrencyQ = await client.query(`select upper(coalesce(public.get_base_currency(), 'YER')) as base_currency`);
const baseCurrency = String(baseCurrencyQ.rows?.[0]?.base_currency || 'YER').toUpperCase();

const ordersQ = await client.query(`
  select
    o.id::text as id,
    o.status,
    o.currency,
    o.fx_rate,
    o.base_total,
    o.party_id::text as party_id,
    o.payment_method,
    o.data,
    o.updated_at
  from public.orders o
  where o.updated_at >= $1::timestamptz
`, [since.toISOString()]);
const orders = ordersQ.rows || [];

const deliveredIds = orders.filter((o) => String(o.status).toLowerCase() === 'delivered').map((o) => String(o.id));
const cancelledIds = orders.filter((o) => String(o.status).toLowerCase() === 'cancelled').map((o) => String(o.id));

const saleOutQ = await client.query(`
  select reference_id::text as order_id, count(*)::int as c
  from public.inventory_movements
  where reference_table='orders'
    and movement_type='sale_out'
    and reference_id = any($1::text[])
  group by reference_id
`, [deliveredIds.length ? deliveredIds : ['']]);
const saleOutMap = toMapCount(saleOutQ.rows, 'order_id', 'c');

const returnInQ = await client.query(`
  select reference_id::text as order_id, count(*)::int as c
  from public.inventory_movements
  where reference_table='orders'
    and movement_type='return_in'
    and reference_id = any($1::text[])
  group by reference_id
`, [orders.length ? orders.map((o) => String(o.id)) : ['']]);
const returnInMap = toMapCount(returnInQ.rows, 'order_id', 'c');

const deliveredJeQ = await client.query(`
  select source_id::text as order_id, count(*)::int as c
  from public.journal_entries
  where source_table='orders'
    and source_event='delivered'
    and source_id = any($1::text[])
  group by source_id
`, [deliveredIds.length ? deliveredIds : ['']]);
const deliveredJeMap = toMapCount(deliveredJeQ.rows, 'order_id', 'c');

const paymentQ = await client.query(`
  select reference_id::text as order_id, coalesce(sum(coalesce(amount,0)),0)::numeric as paid
  from public.payments
  where reference_table='orders'
    and direction='in'
    and reference_id = any($1::text[])
  group by reference_id
`, [orders.length ? orders.map((o) => String(o.id)) : ['']]);
const paidMap = new Map();
for (const r of paymentQ.rows || []) paidMap.set(String(r.order_id), Number(r.paid) || 0);

const checkSet = (name, subset, fn) => {
  if (subset.length === 0) return { name, status: 'N/A', total: 0, passed: 0, failed: 0, sample_failures: [] };
  let passed = 0;
  const failedRows = [];
  for (const o of subset) {
    const result = fn(o);
    if (result.ok) passed += 1;
    else failedRows.push({ id: o.id, reason: result.reason });
  }
  const failed = subset.length - passed;
  return {
    name,
    status: failed === 0 ? 'PASS' : 'FAIL',
    total: subset.length,
    passed,
    failed,
    sample_failures: failedRows.slice(0, 10),
  };
};

const delivered = orders.filter((o) => String(o.status).toLowerCase() === 'delivered');
const cancelled = orders.filter((o) => String(o.status).toLowerCase() === 'cancelled');

const scenarioCashInStoreBase = delivered.filter((o) => getOrderSource(o) === 'in_store' && getPaymentMethod(o) === 'cash' && String(o.currency || '').toUpperCase() === baseCurrency);
const scenarioCashInStoreFx = delivered.filter((o) => getOrderSource(o) === 'in_store' && getPaymentMethod(o) === 'cash' && String(o.currency || '').toUpperCase() !== baseCurrency);
const scenarioCreditBase = delivered.filter((o) => (getPaymentMethod(o) === 'ar' || getInvoiceTerms(o) === 'credit') && String(o.currency || '').toUpperCase() === baseCurrency);
const scenarioCreditFx = delivered.filter((o) => (getPaymentMethod(o) === 'ar' || getInvoiceTerms(o) === 'credit') && String(o.currency || '').toUpperCase() !== baseCurrency);
const scenarioUom = delivered.filter((o) => hasNonBaseUom(o));
const scenarioReturns = orders.filter((o) => {
  const d = getOrderData(o);
  return ['partial', 'full'].includes(String(d.returnStatus || '').toLowerCase()) || Boolean(d.returnedAt);
});
const scenarioVoidAfterDelivery = orders.filter((o) => {
  const d = getOrderData(o);
  return Boolean(d.voidedAt);
});
const scenarioPartyCreditFx = delivered.filter((o) => Boolean(o.party_id) && (getPaymentMethod(o) === 'ar' || getInvoiceTerms(o) === 'credit') && String(o.currency || '').toUpperCase() !== baseCurrency);

const checks = [
  checkSet('CASH_INSTORE_BASE', scenarioCashInStoreBase, (o) => {
    const d = getOrderData(o);
    const paid = Number(paidMap.get(String(o.id)) || 0);
    const hasPaidAt = Boolean(d.paidAt);
    const hasSaleOut = Number(saleOutMap.get(String(o.id)) || 0) > 0;
    const hasJe = Number(deliveredJeMap.get(String(o.id)) || 0) > 0;
    if (!hasSaleOut) return { ok: false, reason: 'missing_sale_out' };
    if (!hasJe) return { ok: false, reason: 'missing_delivered_je' };
    if (!(paid > 0 || hasPaidAt)) return { ok: false, reason: 'missing_paid_marker' };
    return { ok: true };
  }),
  checkSet('CASH_INSTORE_FOREIGN', scenarioCashInStoreFx, (o) => {
    const d = getOrderData(o);
    const hasPaidMarker = Number(paidMap.get(String(o.id)) || 0) > 0 || Boolean(d.paidAt);
    if (!hasPaidMarker) return { ok: false, reason: 'missing_paid_marker' };
    if (!(Number(o.fx_rate) > 0)) return { ok: false, reason: 'invalid_fx_rate' };
    return { ok: true };
  }),
  checkSet('CREDIT_BASE', scenarioCreditBase, (o) => {
    if (!(Number(deliveredJeMap.get(String(o.id)) || 0) > 0)) return { ok: false, reason: 'missing_delivered_je' };
    if (!(Number(saleOutMap.get(String(o.id)) || 0) > 0)) return { ok: false, reason: 'missing_sale_out' };
    return { ok: true };
  }),
  checkSet('CREDIT_FOREIGN', scenarioCreditFx, (o) => {
    if (!(Number(o.fx_rate) > 0)) return { ok: false, reason: 'invalid_fx_rate' };
    if (!(Number(deliveredJeMap.get(String(o.id)) || 0) > 0)) return { ok: false, reason: 'missing_delivered_je' };
    return { ok: true };
  }),
  checkSet('UOM_MIXED_SALES', scenarioUom, (o) => {
    if (!(Number(saleOutMap.get(String(o.id)) || 0) > 0)) return { ok: false, reason: 'missing_sale_out' };
    return { ok: true };
  }),
  checkSet('RETURNS_FLOW', scenarioReturns, (o) => {
    if (!(Number(returnInMap.get(String(o.id)) || 0) > 0)) return { ok: false, reason: 'missing_return_in' };
    return { ok: true };
  }),
  checkSet('VOID_AFTER_DELIVERY_FLOW', scenarioVoidAfterDelivery, (o) => {
    if (!(Number(returnInMap.get(String(o.id)) || 0) > 0)) return { ok: false, reason: 'missing_return_in_for_void' };
    return { ok: true };
  }),
  checkSet('PARTY_CREDIT_FOREIGN', scenarioPartyCreditFx, (o) => {
    if (!(Number(o.fx_rate) > 0)) return { ok: false, reason: 'invalid_fx_rate' };
    if (!(Number(deliveredJeMap.get(String(o.id)) || 0) > 0)) return { ok: false, reason: 'missing_delivered_je' };
    return { ok: true };
  }),
  checkSet('CANCELLED_ORDERS', cancelled, (o) => {
    if (Number(deliveredJeMap.get(String(o.id)) || 0) > 0) return { ok: false, reason: 'cancelled_has_delivered_je' };
    return { ok: true };
  }),
];

const hardFails = checks.filter((c) => c.status === 'FAIL');
const passCount = checks.filter((c) => c.status === 'PASS').length;
const naCount = checks.filter((c) => c.status === 'N/A').length;

const report = {
  generated_at: new Date().toISOString(),
  lookback_days: lookbackDays,
  base_currency: baseCurrency,
  totals: {
    orders_scanned: orders.length,
    delivered_scanned: delivered.length,
    cancelled_scanned: cancelled.length,
    pending_now: orders.filter((o) => String(o.status).toLowerCase() === 'pending').length,
  },
  scenarios: checks,
  summary: {
    pass: passCount,
    fail: hardFails.length,
    na: naCount,
    overall: hardFails.length === 0 ? 'PASS' : 'FAIL',
  },
};

const outDir = path.join(process.cwd(), 'backups');
if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const jsonPath = path.join(outDir, `uat_matrix_orders_${stamp}.json`);
const mdPath = path.join(outDir, `uat_matrix_orders_${stamp}.md`);
const latestJsonPath = path.join(outDir, 'uat_matrix_orders_latest.json');
const latestMdPath = path.join(outDir, 'uat_matrix_orders_latest.md');
fs.writeFileSync(jsonPath, JSON.stringify(report, null, 2), 'utf8');
fs.writeFileSync(latestJsonPath, JSON.stringify(report, null, 2), 'utf8');

const lines = [];
lines.push(`# UAT Matrix Report`);
lines.push(``);
lines.push(`- Generated: ${report.generated_at}`);
lines.push(`- Lookback days: ${report.lookback_days}`);
lines.push(`- Base currency: ${report.base_currency}`);
lines.push(`- Orders scanned: ${report.totals.orders_scanned}`);
lines.push(`- Delivered scanned: ${report.totals.delivered_scanned}`);
lines.push(`- Cancelled scanned: ${report.totals.cancelled_scanned}`);
lines.push(`- Pending now: ${report.totals.pending_now}`);
lines.push(`- Overall: ${report.summary.overall}`);
lines.push(``);
lines.push(`| Scenario | Status | Total | Passed | Failed |`);
lines.push(`|---|---:|---:|---:|---:|`);
for (const s of report.scenarios) {
  lines.push(`| ${s.name} | ${s.status} | ${s.total} | ${s.passed} | ${s.failed} |`);
}
lines.push(``);
for (const s of report.scenarios.filter((x) => x.status === 'FAIL')) {
  lines.push(`## ${s.name} Failures`);
  lines.push(``);
  for (const f of s.sample_failures || []) lines.push(`- ${f.id}: ${f.reason}`);
  lines.push(``);
}
fs.writeFileSync(mdPath, lines.join('\n'), 'utf8');
fs.writeFileSync(latestMdPath, lines.join('\n'), 'utf8');

console.log(JSON.stringify({
  overall: report.summary.overall,
  pass: report.summary.pass,
  fail: report.summary.fail,
  na: report.summary.na,
  jsonPath,
  mdPath,
  latestJsonPath,
  latestMdPath,
}, null, 2));

await client.end();
