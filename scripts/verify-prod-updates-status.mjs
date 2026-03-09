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

await client.connect();
try {
  const checks = await client.query(`
    with delivered as (
      select o.id
      from public.orders o
      where o.status='delivered'
        and o.created_at >= now() - interval '180 days'
        and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
    ),
    oic as (
      select order_id, sum(coalesce(total_cost,0)) as oic_cost
      from public.order_item_cogs
      group by order_id
    ),
    mv as (
      select (reference_id)::uuid as order_id,
             sum(coalesce(nullif(total_cost,0), quantity*coalesce(nullif(unit_cost,0),0),0)) as mv_cost
      from public.inventory_movements
      where reference_table='orders' and movement_type='sale_out'
        and occurred_at >= now() - interval '180 days'
      group by (reference_id)::uuid
    )
    select
      position('reconcile_purchase_order_receipt_status(p_order_id)' in pg_get_functiondef('public.create_purchase_return_v2(uuid,jsonb,text,timestamptz,text)'::regprocedure)) > 0 as purchase_return_fix_applied,
      to_regprocedure('public.sync_order_item_cogs_from_sale_out(uuid)') is not null as cogs_sync_function_exists,
      exists (
        select 1
        from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = 'inventory_movements'
          and t.tgname = 'trg_sync_order_item_cogs_from_sale_out'
          and not t.tgisinternal
      ) as cogs_sync_trigger_exists,
      (
        select count(*)::int
        from delivered d
        join oic on oic.order_id=d.id
        join mv on mv.order_id=d.id
        where abs(coalesce(oic.oic_cost,0)-coalesce(mv.mv_cost,0)) > 0.01
      ) as cogs_mismatch_orders_180d
  `);
  console.log(JSON.stringify(checks.rows?.[0] || {}, null, 2));
} finally {
  await client.end();
}
