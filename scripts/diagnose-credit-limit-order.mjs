import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
const ref = String(process.env.ORDER_REF || '').trim();
if (!password) {
  console.error('Missing DBPW or SUPABASE_DB_PASSWORD');
  process.exit(1);
}
if (!ref) {
  console.error('Missing ORDER_REF');
  process.exit(1);
}

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const run = async () => {
  await client.connect();
  try {
    const { rows: orderRows } = await client.query(
      `
      with q as (
        select
          o.id,
          o.status,
          o.currency,
          o.total,
          o.base_total,
          o.customer_auth_user_id,
          o.party_id,
          o.created_at,
          o.data,
          coalesce(
            nullif(to_jsonb(o)->>'invoice_number', ''),
            nullif(to_jsonb(o)->>'invoiceNumber', ''),
            nullif(o.data->>'invoiceNumber', ''),
            nullif(o.data->>'invoice_number', '')
          ) as invoice_number
        from public.orders o
      )
      select *
      from q
      where upper(right(id::text, 6)) = upper($1)
         or upper(coalesce(invoice_number, '')) = upper($1)
         or upper(right(coalesce(invoice_number, ''), 6)) = upper($1)
      order by created_at desc
      limit 1
      `,
      [ref]
    );
    if (!orderRows.length) {
      console.log(JSON.stringify({ found: false, ref }, null, 2));
      return;
    }
    const o = orderRows[0];
    const data = (o.data && typeof o.data === 'object') ? o.data : {};
    const customerId = data.customerId || null;
    const partyId = o.party_id || data.partyId || null;
    const currency = String(o.currency || 'YER').toUpperCase();
    const total = Number(data.total ?? o.total ?? 0) || 0;

    const { rows: customerRows } = customerId
      ? await client.query(
        `select auth_user_id, customer_type, credit_limit, current_balance, payment_terms from public.customers where auth_user_id = $1::uuid limit 1`,
        [customerId]
      )
      : { rows: [] };

    const { rows: partyRows } = partyId
      ? await client.query(
        `select id, name, credit_limit_base, credit_hold, credit_net_days from public.financial_parties where id = $1::uuid limit 1`,
        [partyId]
      )
      : { rows: [] };

    const { rows: pclRows } = partyId
      ? await client.query(
        `select currency_code, credit_limit, credit_hold, net_days from public.party_credit_limits where party_id = $1::uuid order by currency_code`,
        [partyId]
      )
      : { rows: [] };

    const { rows: balRows } = partyId
      ? await client.query(
        `select * from public.compute_party_ar_balance_by_currency($1::uuid, null)`,
        [partyId]
      )
      : { rows: [] };

    const { rows: checkPartyRows } = partyId
      ? await client.query(
        `select public.check_party_credit_limit($1::uuid, $2::numeric, $3::text) as ok`,
        [partyId, total, currency]
      )
      : { rows: [] };

    const { rows: checkCustomerRows } = customerId
      ? await client.query(
        `select public.check_customer_credit_limit($1::uuid, $2::numeric) as ok`,
        [customerId, total]
      )
      : { rows: [] };

    console.log(JSON.stringify({
      found: true,
      ref,
      order: {
        id: o.id,
        status: o.status,
        invoice_number: o.invoice_number || null,
        currency,
        total,
        base_total: o.base_total,
        customer_auth_user_id: o.customer_auth_user_id,
        customerId: customerId || null,
        party_id: partyId || null,
        invoiceTerms: data.invoiceTerms || null,
        isCreditSale: data.isCreditSale ?? null
      },
      customer: customerRows[0] || null,
      party: partyRows[0] || null,
      party_limits: pclRows,
      party_balances: balRows,
      check_party_credit_limit: checkPartyRows[0]?.ok ?? null,
      check_customer_credit_limit: checkCustomerRows[0]?.ok ?? null
    }, null, 2));
  } finally {
    await client.end();
  }
};

run().catch((e) => {
  console.error('diagnose_credit_limit_order_failed:', e?.message || e);
  process.exit(1);
});
