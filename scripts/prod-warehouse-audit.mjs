import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

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

const q1 = `
select
  (select count(*) from public.warehouses) as warehouses_total,
  (select count(*) from public.warehouses where coalesce(is_active,true)=true) as warehouses_active,
  (select array_agg(w.id::text order by w.created_at asc) from public.warehouses w where coalesce(w.is_active,true)=true) as active_warehouse_ids,
  (select count(*) from public.stock_management) as stock_rows,
  (select count(*) from public.stock_management where warehouse_id is null) as stock_null_warehouse,
  (select count(*) from public.inventory_movements) as movements_rows,
  (select count(*) from public.inventory_movements where warehouse_id is null) as movements_null_warehouse,
  (select count(*) from public.stock_management where available_quantity < 0) as stock_negative_available,
  (select count(*) from public.stock_management where reserved_quantity < 0) as stock_negative_reserved,
  (select count(*) from public.stock_management where reserved_quantity > available_quantity + 0.000001) as stock_reserved_gt_available
`;

const q2 = `
with dup as (
  select item_id, warehouse_id, count(*) as c
  from public.stock_management
  group by item_id, warehouse_id
  having count(*) > 1
)
select count(*) as duplicate_item_warehouse_rows from dup
`;

const q3 = `
select
  (select count(*) from public.warehouse_transfers) as transfers_total,
  (select count(*) from public.warehouse_transfers where status='pending') as transfers_pending,
  (select count(*) from public.warehouse_transfers where status='completed') as transfers_completed,
  (select count(*) from public.warehouse_transfers wt where wt.from_warehouse_id = wt.to_warehouse_id) as transfers_same_source_destination,
  (
    select count(*)
    from public.warehouse_transfer_items wti
    join public.warehouse_transfers wt on wt.id = wti.transfer_id
    where wt.status = 'completed'
      and coalesce(wti.transferred_quantity,0) + 0.000001 < coalesce(wti.quantity,0)
  ) as completed_transfer_items_not_fully_transferred
`;

const q4 = `
with t as (
  select wt.id::text as transfer_id, wt.from_warehouse_id, wt.to_warehouse_id, wti.item_id::text as item_id
  from public.warehouse_transfers wt
  join public.warehouse_transfer_items wti on wti.transfer_id = wt.id
  where wt.status = 'completed'
),
m_out as (
  select reference_id, warehouse_id, item_id::text as item_id, count(*) as c
  from public.inventory_movements
  where reference_table='warehouse_transfers'
    and movement_type in ('adjust_out','transfer_out')
  group by reference_id, warehouse_id, item_id::text
),
m_in as (
  select reference_id, warehouse_id, item_id::text as item_id, count(*) as c
  from public.inventory_movements
  where reference_table='warehouse_transfers'
    and movement_type in ('adjust_in','transfer_in')
  group by reference_id, warehouse_id, item_id::text
)
select
  count(*) filter (where coalesce(o.c,0)=0) as completed_missing_out_movement,
  count(*) filter (where coalesce(i.c,0)=0) as completed_missing_in_movement
from t
left join m_out o on o.reference_id=t.transfer_id and o.warehouse_id=t.from_warehouse_id and o.item_id=t.item_id
left join m_in i on i.reference_id=t.transfer_id and i.warehouse_id=t.to_warehouse_id and i.item_id=t.item_id
`;

const q5 = `
with delivered as (
  select o.id::text as order_id
  from public.orders o
  where o.status='delivered'
    and coalesce(nullif(trim(coalesce(o.data->>'voidedAt','')),''), '') = ''
    and o.created_at >= now() - interval '30 days'
),
mov as (
  select reference_id, count(*) as c
  from public.inventory_movements
  where reference_table='orders'
    and movement_type='sale_out'
    and occurred_at >= now() - interval '30 days'
  group by reference_id
)
select
  count(*) as delivered_last_30d,
  count(*) filter (where coalesce(m.c,0)=0) as delivered_without_sale_out_last_30d
from delivered d
left join mov m on m.reference_id = d.order_id
`;

const q6 = `
select
  to_regprocedure('public.complete_warehouse_transfer(uuid)') is not null as has_complete_transfer,
  to_regprocedure('public.reserve_stock_for_order(jsonb,uuid,uuid)') is not null as has_reserve_stock_wh,
  to_regprocedure('public.deduct_stock_on_delivery_v2(uuid,jsonb,uuid)') is not null as has_deduct_stock_wh,
  to_regprocedure('public.receive_purchase_order_partial(uuid,jsonb,timestamptz)') is not null as has_receive_po_partial,
  to_regprocedure('public.post_order_delivery(uuid)') is not null as has_post_order_delivery,
  to_regprocedure('public.post_payment(uuid)') is not null as has_post_payment
`;

const q7 = `
select
  (select count(*) from public.payments p where p.reference_table='orders' and p.direction='in' and coalesce(base_amount,0) <= 0 and p.created_at >= now() - interval '90 days') as order_payments_nonpositive_base_90d,
  (select count(*) from public.journal_entries je where je.source_table='orders' and je.source_event in ('delivered','invoiced') and je.created_at >= now() - interval '90 days') as order_postings_90d
`;

const q8 = `
select
  (select count(*) from public.ar_open_items where status='open') as ar_open_items_open_total,
  (select count(*) from public.ar_open_items where status='open' and coalesce(open_balance,0) < -0.000001) as ar_open_items_negative_open_balance,
  (select count(*) from public.ar_open_items where status='open' and coalesce(open_balance,0) - coalesce(original_amount,0) > 0.000001) as ar_open_items_open_gt_original
`;

const q9 = `
with item_wh as (
  select
    o.id,
    (x.value->>'itemId') as item_id,
    nullif(trim(x.value->>'warehouseId'),'') as warehouse_id
  from public.orders o
  cross join lateral jsonb_array_elements(coalesce(o.data->'items','[]'::jsonb)) x(value)
  where o.status='delivered'
    and o.created_at >= now() - interval '30 days'
)
select
  (select count(distinct warehouse_id) from public.stock_management where coalesce(available_quantity,0) > 0) as warehouses_with_positive_stock,
  (select count(distinct warehouse_id) from public.inventory_movements where movement_type='purchase_in' and occurred_at >= now() - interval '90 days') as warehouses_with_purchase_in_90d,
  (select count(distinct warehouse_id) from public.inventory_movements where movement_type='sale_out' and occurred_at >= now() - interval '30 days') as warehouses_with_sale_out_30d,
  (select count(*) from item_wh) as delivered_item_lines_30d,
  (select count(*) from item_wh where warehouse_id is not null) as delivered_item_lines_with_wh_30d
`;

const q10 = `
select
  exists(select 1 from pg_indexes where schemaname='public' and tablename='stock_management' and indexname='idx_stock_item_warehouse') as has_idx_stock_item_warehouse,
  exists(select 1 from pg_indexes where schemaname='public' and tablename='inventory_movements' and indexname='idx_inventory_movements_warehouse_item_date') as has_idx_im_wh_item_date,
  exists(select 1 from pg_indexes where schemaname='public' and tablename='inventory_movements' and indexname='idx_inventory_movements_warehouse_batch') as has_idx_im_wh_batch
`;

const q11 = `
select
  coalesce(array_agg(indexname order by indexname), '{}'::text[]) as inventory_movement_warehouse_indexes
from pg_indexes
where schemaname='public'
  and tablename='inventory_movements'
  and indexdef ilike '%warehouse%'
`;

const q12 = `
select
  exists(
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='orders' and t.tgname='trg_orders_post_delivery' and not t.tgisinternal
  ) as has_orders_post_delivery_trigger,
  exists(
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='orders' and t.tgname='trg_orders_require_sale_out_on_delivered' and not t.tgisinternal
  ) as has_orders_sale_out_guard_trigger
`;

await client.connect();
const result = {};
try {
  result.generated_at = new Date().toISOString();
  result.health = (await client.query(`select public.app_schema_healthcheck() as health`)).rows?.[0]?.health || null;
  result.overview = (await client.query(q1)).rows?.[0] || {};
  result.duplicates = (await client.query(q2)).rows?.[0] || {};
  result.transfers = (await client.query(q3)).rows?.[0] || {};
  result.transfer_movements = (await client.query(q4)).rows?.[0] || {};
  result.sales_deduction = (await client.query(q5)).rows?.[0] || {};
  result.functions = (await client.query(q6)).rows?.[0] || {};
  result.payments = (await client.query(q7)).rows?.[0] || {};
  result.ar_reconciliation = (await client.query(q8)).rows?.[0] || {};
  result.multiwarehouse_usage = (await client.query(q9)).rows?.[0] || {};
  result.indexes = (await client.query(q10)).rows?.[0] || {};
  result.inventory_movement_index_names = (await client.query(q11)).rows?.[0] || {};
  result.order_triggers = (await client.query(q12)).rows?.[0] || {};
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'backups', 'prod_warehouse_audit.json');
fs.writeFileSync(outPath, JSON.stringify(result, null, 2), 'utf8');
console.log(outPath);
