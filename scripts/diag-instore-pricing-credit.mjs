import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) {
  console.error('Missing DBPW');
  process.exit(1);
}

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
  const recent = await client.query(`
    select
      o.id,
      o.status,
      o.currency,
      o.fx_rate,
      o.base_total,
      o.total,
      o.created_at,
      o.party_id,
      coalesce(o.data->>'inStoreFailureReason','') as reason,
      o.data->>'warehouseId' as warehouse_id,
      o.data->'items'->0->>'id' as first_item_id,
      o.data->'items'->0->>'unitType' as first_item_unit_type,
      o.data->'items'->0->>'price' as first_item_price,
      o.data->'items'->0->>'quantity' as first_item_qty,
      o.data->'items'->0->>'uomQtyInBase' as first_uom_qty
    from public.orders o
    where coalesce(o.data->>'orderSource','')='in_store'
    order by o.created_at desc
    limit 50
  `);
  console.log('recent_orders');
  console.table(recent.rows.map((r) => ({
    id: r.id,
    status: r.status,
    currency: r.currency,
    fx_rate: r.fx_rate,
    total: Number(r.total || 0),
    base_total: Number(r.base_total || 0),
    reason: r.reason,
    first_item_id: r.first_item_id,
    first_item_price: Number(r.first_item_price || 0),
  })));
  console.log('recent_orders_json');
  console.log(JSON.stringify(recent.rows.slice(0, 20), null, 2));

  const creditFails = recent.rows.filter((r) => String(r.reason || '').toUpperCase().includes('CREDIT'));
  console.log('credit_failures', creditFails.length);
  for (const r of creditFails.slice(0, 10)) {
    const party = String(r.party_id || '').trim();
    if (!party) continue;
    const summary = await client.query(`select public.get_party_credit_summary($1::uuid) as s`, [party]);
    console.log('credit_failure_order', r.id, 'party', party);
    console.log(JSON.stringify(summary.rows[0]?.s || null, null, 2));
  }

  const big = recent.rows.find((r) => Number(r.total || 0) > 1000000 && String(r.first_item_id || '').trim());
  if (big) {
    const itemId = String(big.first_item_id);
    const wh = String(big.warehouse_id || '').trim();
    if (wh) {
      const fx = await client.query(`select public.get_base_currency() as base, public.get_fx_rate('YER', current_date, 'operational') as fx_yer, public.get_fx_rate('SAR', current_date, 'operational') as fx_sar`);
      console.log('fx_snapshot', fx.rows[0]);
      const y = await client.query(`select * from public.get_fefo_pricing($1::text, $2::uuid, 1, null, 'YER', null)`, [itemId, wh]);
      const s = await client.query(`select * from public.get_fefo_pricing($1::text, $2::uuid, 1, null, 'SAR', null)`, [itemId, wh]);
      console.log('sample_big_order_item', { order_id: big.id, item_id: itemId, warehouse_id: wh });
      console.log('price_yer', y.rows[0] || null);
      console.log('price_sar', s.rows[0] || null);
    }
  }

  const summary = await client.query(`
    with x as (
      select
        id,
        status,
        party_id,
        currency,
        fx_rate,
        base_total,
        coalesce(data->>'inStoreFailureReason','') as reason,
        coalesce(data->>'invoiceTerms','') as terms,
        coalesce((data->>'isCreditSale')::boolean,false) as is_credit
      from public.orders
      where coalesce(data->>'orderSource','')='in_store'
        and created_at >= now()-interval '7 days'
    )
    select
      count(*) filter (where status='pending' and reason<>'') as pending_fail,
      count(*) filter (where reason ilike '%CREDIT%') as reason_credit_token,
      count(*) filter (where reason ilike '%BELOW_COST%') as reason_below_cost,
      count(*) filter (where status='pending' and party_id is not null) as pending_with_party,
      count(*) filter (where status='pending' and is_credit) as pending_credit,
      count(*) filter (where status='pending' and terms='credit') as pending_terms_credit
    from x
  `);
  console.log('pending_summary');
  console.log(JSON.stringify(summary.rows[0] || {}, null, 2));

  const pendingParty = await client.query(`
    select
      id,
      currency,
      fx_rate,
      base_total,
      status,
      party_id,
      coalesce(data->>'invoiceTerms','') as terms,
      coalesce((data->>'isCreditSale')::boolean,false) as is_credit,
      coalesce(data->>'inStoreFailureReason','') as reason
    from public.orders
    where coalesce(data->>'orderSource','')='in_store'
      and status='pending'
      and party_id is not null
    order by created_at desc
    limit 20
  `);
  console.log('pending_with_party');
  console.log(JSON.stringify(pendingParty.rows, null, 2));

  const uniqParties = Array.from(new Set(pendingParty.rows.map((r) => String(r.party_id || '').trim()).filter(Boolean))).slice(0, 5);
  for (const partyId of uniqParties) {
    const s = await client.query(`select public.get_party_credit_summary($1) as summary`, [partyId]);
    console.log('party_credit_summary', partyId);
    console.log(JSON.stringify(s.rows[0]?.summary || null, null, 2));
  }

  await client.end();
};

run().catch(async (e) => {
  try { await client.end(); } catch {}
  console.error('diag_failed', e?.message || e);
  process.exit(1);
});
