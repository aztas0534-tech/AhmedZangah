import { Client } from 'pg';
import crypto from 'node:crypto';

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

const one = async (sql, params = []) => (await client.query(sql, params)).rows?.[0] || null;
const many = async (sql, params = []) => (await client.query(sql, params)).rows || [];

await client.connect();
try {
  const baseRow = await one(`select upper(coalesce(public.get_base_currency(),'SAR')) as code`);
  const baseCurrency = String(baseRow?.code || 'SAR').toUpperCase();
  const foreignCurrency = baseCurrency === 'USD' ? 'YER' : 'USD';
  const fx = foreignCurrency === 'USD' ? 3.75 : 250;

  const supplier = await one(`select id from public.suppliers order by created_at asc nulls last limit 1`);
  if (!supplier?.id) throw new Error('No supplier found in production');
  const actor = await one(
    `select auth_user_id
     from public.admin_users
     where is_active = true
       and role in ('owner','manager','employee','cashier','delivery')
     order by (case when role = 'owner' then 1 else 0 end) desc, created_at asc nulls last
     limit 1`
  );
  if (!actor?.auth_user_id) throw new Error('No active staff user found in production');
  await client.query(
    `select
       set_config('request.jwt.claim.sub', $1::text, false),
       set_config('request.jwt.claim.role', 'authenticated', false),
       set_config('request.jwt.claims', json_build_object('sub',$1::text,'role','authenticated')::text, false)`,
    [actor.auth_user_id]
  );

  const wh = await one(`select id from public.warehouses where is_active = true order by created_at asc nulls last limit 1`);
  if (!wh?.id) throw new Error('No active warehouse found in production');

  const branch = await one(`select id from public.branches order by created_at asc nulls last limit 1`);
  const company = await one(`select id from public.companies order by created_at asc nulls last limit 1`);
  if (!branch?.id || !company?.id) throw new Error('Missing branch/company');

  const itemId = `smoke-pr-${crypto.randomUUID()}`;
  const itemSuffix = itemId.slice(-6);
  await client.query(
    `insert into public.menu_items(id, name, price, cost_price, unit_type, status, category, is_food, expiry_required, data)
     values ($1, jsonb_build_object('ar',$2::text,'en',$3::text), 100, 10, 'piece', 'active', 'qat', false, false, jsonb_build_object('createdFor','smoke-return-uom-fx'))`,
    [itemId, `صنف فحص مرتجع شراء ${itemSuffix}`, `Purchase Return Smoke Item ${itemSuffix}`]
  );

  await client.query(`select public.upsert_item_packaging_uom($1, 6, 12)`, [itemId]);
  const carton = await one(
    `select u.id as uom_id, iuu.qty_in_base
     from public.item_uom_units iuu
     join public.uom u on u.id = iuu.uom_id
     where iuu.item_id = $1 and iuu.is_active = true and lower(u.code) = 'carton'
     limit 1`,
    [itemId]
  );
  if (!carton?.uom_id || Number(carton?.qty_in_base || 0) <= 1) throw new Error('Carton UOM not configured');

  const po = await one(
    `insert into public.purchase_orders(
       supplier_id,status,purchase_date,items_count,total_amount,paid_amount,notes,created_by,
       warehouse_id,branch_id,company_id,payment_terms,net_days,po_number,currency,fx_rate,base_total,fx_locked
     )
     values(
       $1,'draft',current_date,1,1200,0,$2,null,
       $3,$4,$5,'cash',0,$6,$7,$8::numeric,1200::numeric*$8::numeric,true
     )
     returning id`,
    [supplier.id, `SMOKE-RET-UOM-FX-${itemId.slice(-8)}`, wh.id, branch.id, company.id, `PO-SMOKE-${Date.now()}`, foreignCurrency, fx]
  );

  const pi = await one(
    `insert into public.purchase_items(purchase_order_id,item_id,quantity,uom_id,unit_cost,total_cost)
     values($1,$2,1,$3,1200,1200)
     returning id,quantity,qty_base,uom_id,unit_cost,unit_cost_foreign,unit_cost_base,total_cost`,
    [po.id, itemId, carton.uom_id]
  );

  const receipt = await one(
    `select public.receive_purchase_order_partial(
      $1::uuid,
      jsonb_build_array(jsonb_build_object('itemId',$2::text,'quantity',$3::numeric,'unitCost',1200::numeric)),
      now()::timestamptz
    ) as id`,
    [po.id, itemId, Number(carton.qty_in_base)]
  );
  if (!receipt?.id) throw new Error('Failed to create purchase receipt');

  const before = await one(
    `select
      pi.quantity as po_qty_trx,
      pi.qty_base as po_qty_base,
      pi.unit_cost as po_unit_cost_trx,
      pi.unit_cost_foreign as po_unit_cost_foreign_base_uom,
      pi.unit_cost_base as po_unit_cost_base,
      pi.total_cost as po_total_trx,
      po.currency as po_currency,
      po.fx_rate as po_fx_rate
    from public.purchase_items pi
    join public.purchase_orders po on po.id = pi.purchase_order_id
    where pi.id = $1`,
    [pi.id]
  );

  const ret = await one(
    `select public.create_purchase_return_v2(
      $1::uuid,
      jsonb_build_array(jsonb_build_object('itemId',$2::text,'quantity',$3::numeric)),
      $4::text,
      now()::timestamptz,
      $5::text
    ) as id`,
    [po.id, itemId, Number(carton.qty_in_base), 'Smoke return with carton UOM in foreign currency', `idem:${po.id}:smoke:${Date.now()}`]
  );
  if (!ret?.id) throw new Error('Failed to create purchase return');

  const after = await one(
    `with pri as (
       select coalesce(sum(total_cost),0) as pri_total, coalesce(sum(quantity),0) as pri_qty, min(unit_cost) as pri_unit_cost
       from public.purchase_return_items
       where return_id = $1 and item_id = $2
     ),
     mv as (
       select coalesce(sum(total_cost),0) as mv_total, coalesce(sum(quantity),0) as mv_qty
       from public.inventory_movements
       where reference_table='purchase_returns' and reference_id=$1::text and movement_type='return_out' and item_id=$2
     ),
     je as (
       select id, currency_code, fx_rate, foreign_amount, party_id
       from public.journal_entries
       where source_table='inventory_movements'
         and source_event='return_out'
         and source_id in (
           select im.id::text
           from public.inventory_movements im
           where im.reference_table='purchase_returns' and im.reference_id=$1::text and im.item_id=$2 and im.movement_type='return_out'
         )
       order by created_at desc
       limit 1
     )
     select
       pri.pri_total, pri.pri_qty, pri.pri_unit_cost,
       mv.mv_total, mv.mv_qty,
       je.currency_code as je_currency_code, je.fx_rate as je_fx_rate, je.foreign_amount as je_foreign_amount, je.party_id as je_party_id,
       abs(coalesce(pri.pri_total,0)-coalesce(mv.mv_total,0)) <= 0.01 as cost_match,
       (je.currency_code is not null and je.fx_rate is not null and je.party_id is not null) as je_has_fx_party
     from pri, mv
     left join je on true`,
    [ret.id, itemId]
  );

  const lines = await many(
    `select jl.debit, jl.credit, jl.currency_code, jl.fx_rate, jl.foreign_amount, jl.party_id
     from public.journal_lines jl
     join public.journal_entries je on je.id = jl.journal_entry_id
     where je.source_table='inventory_movements'
       and je.source_event='return_out'
       and je.source_id in (
         select im.id::text
         from public.inventory_movements im
         where im.reference_table='purchase_returns' and im.reference_id=$1::text and im.item_id=$2 and im.movement_type='return_out'
       )
     order by jl.created_at asc`,
    [ret.id, itemId]
  );

  console.log(JSON.stringify({
    smoke: {
      itemId,
      purchaseOrderId: po.id,
      receiptId: receipt.id,
      returnId: ret.id,
      baseCurrency,
      foreignCurrency,
      cartonQtyInBase: Number(carton.qty_in_base),
    },
    before,
    after,
    journalLines: lines,
  }, null, 2));
} finally {
  await client.end();
}
