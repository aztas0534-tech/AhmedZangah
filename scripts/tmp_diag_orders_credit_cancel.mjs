import { Client } from 'pg';

const password = String(process.env.DBPW || '').trim();
if (!password) {
  console.error('Missing DBPW');
  process.exit(1);
}

const invoiceNumbers = (process.env.INVOICES || 'INV-82150,INV-82149,INV-82148')
  .split(',')
  .map((x) => x.trim())
  .filter(Boolean);

const searchRecentInstore = String(process.env.SEARCH_RECENT_INSTORE || '1') === '1';

const client = new Client({
  host: 'aws-1-ap-south-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
});

const run = async () => {
  await client.connect();
  const ordersRes = await client.query(
    `
    select
      o.id,
      o.status,
      o.created_at,
      o.updated_at,
      o.party_id,
      o.currency,
      o.fx_rate,
      o.total,
      o.base_total,
      o.payment_method,
      o.delivery_zone_id,
      o.warehouse_id,
      o.data->>'invoiceNumber' as invoice_no,
      o.data->>'orderSource' as order_source,
      o.data->>'invoiceTerms' as invoice_terms,
      o.data->>'isCreditSale' as is_credit_sale,
      o.data->>'paidAt' as paid_at,
      o.data->'invoiceSnapshot'->>'issuedAt' as invoice_issued_at
    from public.orders o
    where (o.data->>'invoiceNumber') = any($1::text[])
    order by o.created_at desc
    `,
    [invoiceNumbers],
  );

  const orders = ordersRes.rows || [];
  if (searchRecentInstore) {
    const recentRes = await client.query(
      `
      select
        o.id,
        o.status,
        o.created_at,
        o.party_id,
        o.currency,
        o.total,
        o.data->>'invoiceNumber' as invoice_no,
        o.data->>'inStoreFailureReason' as failure_reason,
        o.data->>'orderSource' as order_source
      from public.orders o
      where coalesce(o.data->>'orderSource','')='in_store'
      order by o.created_at desc
      limit 20
      `,
    );
    console.log('recent_instore_orders');
    console.table(recentRes.rows || []);
    for (const r of recentRes.rows || []) {
      if (!orders.find((x) => String(x.id) === String(r.id))) orders.push(r);
    }
  }
  console.log('orders');
  console.table(orders);

  for (const o of orders) {
    const orderId = String(o.id);
    const partyId = o.party_id ? String(o.party_id) : '';
    console.log(`order=${orderId} invoice=${o.invoice_no}`);

    const errLog = await client.query(
      `
      select performed_at, action, details, metadata
      from public.system_audit_logs
      where details = $1
         or coalesce(metadata->>'orderId','') = $1
      order by performed_at desc
      limit 20
      `,
      [orderId],
    );
    console.log('audit_logs');
    console.table(
      (errLog.rows || []).map((r) => ({
        performed_at: r.performed_at,
        action: r.action,
        details: r.details,
        reason_code: r.metadata?.reason_code || r.metadata?.reason || r.metadata?.error || '',
      })),
    );

    if (!partyId) continue;

    const partyRes = await client.query(
      `
      select id, name, credit_limit_base, credit_hold, is_active
      from public.financial_parties
      where id = $1
      `,
      [partyId],
    );
    console.log('party');
    console.table(partyRes.rows || []);

    const limitsRes = await client.query(
      `
      select currency_code, credit_limit, credit_hold
      from public.party_credit_limits
      where party_id = $1
      order by currency_code
      `,
      [partyId],
    );
    console.log('party_credit_limits');
    console.table(limitsRes.rows || []);

    const baseBalanceRes = await client.query(
      `select public.compute_party_ar_balance($1) as ar_base`,
      [partyId],
    );
    console.log('ar_base');
    console.table(baseBalanceRes.rows || []);

    const balByCurrencyRes = await client.query(
      `select * from public.compute_party_ar_balance_by_currency($1, null)`,
      [partyId],
    );
    console.log('ar_by_currency');
    console.table(balByCurrencyRes.rows || []);

    const checkRes = await client.query(
      `
      select
        public.check_party_credit_limit($1, $2, $3) as check_with_order_currency,
        public.check_party_credit_limit($1, $4, $5) as check_base_100
      `,
      [partyId, Number(o.total || 0), String(o.currency || ''), 100, 'SAR'],
    );
    console.log('credit_check_probe');
    console.table(checkRes.rows || []);
  }

  await client.end();
};

run().catch(async (e) => {
  try {
    await client.end();
  } catch {}
  console.error('diag_failed:', e?.message || e);
  process.exit(1);
});
