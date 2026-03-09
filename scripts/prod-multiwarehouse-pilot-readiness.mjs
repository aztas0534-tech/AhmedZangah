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

const checks = [
  {
    key: 'schema_health_ok',
    sql: `select (public.app_schema_healthcheck()->>'ok')::boolean as v`,
    pass: (v) => v === true,
  },
  {
    key: 'warehouses_active_ge_2',
    sql: `select count(*)::int as v from public.warehouses where coalesce(is_active,true)=true`,
    pass: (v) => Number(v) >= 2,
  },
  {
    key: 'stock_has_no_null_warehouse',
    sql: `select count(*)::int as v from public.stock_management where warehouse_id is null`,
    pass: (v) => Number(v) === 0,
  },
  {
    key: 'movements_has_no_null_warehouse',
    sql: `select count(*)::int as v from public.inventory_movements where warehouse_id is null`,
    pass: (v) => Number(v) === 0,
  },
  {
    key: 'stock_item_wh_no_duplicates',
    sql: `with d as (select item_id, warehouse_id, count(*) c from public.stock_management group by item_id, warehouse_id having count(*)>1) select count(*)::int as v from d`,
    pass: (v) => Number(v) === 0,
  },
  {
    key: 'stock_no_negative_available',
    sql: `select count(*)::int as v from public.stock_management where coalesce(available_quantity,0) < 0`,
    pass: (v) => Number(v) === 0,
  },
  {
    key: 'stock_no_reserved_gt_available',
    sql: `select count(*)::int as v from public.stock_management where coalesce(reserved_quantity,0) - coalesce(available_quantity,0) > 0.000001`,
    pass: (v) => Number(v) === 0,
  },
  {
    key: 'functions_present_core',
    sql: `
      select (
        to_regprocedure('public.complete_warehouse_transfer(uuid)') is not null
        and to_regprocedure('public.reserve_stock_for_order(jsonb,uuid,uuid)') is not null
        and to_regprocedure('public.deduct_stock_on_delivery_v2(uuid,jsonb,uuid)') is not null
        and to_regprocedure('public.receive_purchase_order_partial(uuid,jsonb,timestamptz)') is not null
      ) as v`,
    pass: (v) => v === true,
  },
  {
    key: 'orders_triggers_present',
    sql: `
      select (
        exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='orders' and t.tgname='trg_orders_post_delivery' and not t.tgisinternal)
        and exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='orders' and t.tgname='trg_orders_require_sale_out_on_delivered' and not t.tgisinternal)
      ) as v`,
    pass: (v) => v === true,
  },
  {
    key: 'delivered_without_sale_out_30d',
    sql: `
      with d as (
        select o.id::text as order_id
        from public.orders o
        where o.status='delivered'
          and o.created_at >= now() - interval '30 days'
      ),
      m as (
        select reference_id, count(*) c
        from public.inventory_movements
        where reference_table='orders' and movement_type='sale_out'
          and occurred_at >= now() - interval '30 days'
        group by reference_id
      )
      select count(*) filter (where coalesce(m.c,0)=0)::int as v
      from d left join m on m.reference_id=d.order_id`,
    pass: (v) => Number(v) === 0,
  },
  {
    key: 'ar_open_items_negative_open_balance',
    sql: `select count(*)::int as v from public.ar_open_items where status='open' and coalesce(open_balance,0) < -0.000001`,
    pass: (v) => Number(v) === 0,
  },
  {
    key: 'multiwarehouse_activity_present_90d',
    sql: `
      select greatest(
        (select count(distinct warehouse_id) from public.inventory_movements where movement_type='purchase_in' and occurred_at >= now() - interval '90 days'),
        (select count(distinct warehouse_id) from public.inventory_movements where movement_type='sale_out' and occurred_at >= now() - interval '90 days')
      )::int as v`,
    pass: (v) => Number(v) >= 2,
  },
  {
    key: 'transfers_completed_present_90d',
    sql: `select count(*)::int as v from public.warehouse_transfers where status='completed' and created_at >= now() - interval '90 days'`,
    pass: (v) => Number(v) >= 1,
  },
];

await client.connect();
const rows = [];
try {
  for (const c of checks) {
    const r = await client.query(c.sql);
    const value = r.rows?.[0]?.v;
    const ok = c.pass(value);
    rows.push({ key: c.key, ok, value });
  }
} finally {
  await client.end();
}

const summary = {
  generated_at: new Date().toISOString(),
  pass_count: rows.filter((r) => r.ok).length,
  fail_count: rows.filter((r) => !r.ok).length,
  checks: rows,
};

const out = path.join(process.cwd(), 'backups', 'prod_multiwarehouse_pilot_readiness.json');
fs.writeFileSync(out, JSON.stringify(summary, null, 2), 'utf8');
console.log(out);
