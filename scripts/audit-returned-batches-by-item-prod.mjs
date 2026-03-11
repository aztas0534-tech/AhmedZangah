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

await client.connect();
try {
  const actor = (await client.query(`
    select auth_user_id
    from public.admin_users
    where is_active = true
    order by (case when role='owner' then 1 else 0 end) desc, created_at asc nulls last
    limit 1
  `)).rows[0];
  await client.query(
    `select
      set_config('request.jwt.claim.sub',$1::text,false),
      set_config('request.jwt.claim.role','authenticated',false),
      set_config('request.jwt.claims',json_build_object('sub',$1::text,'role','authenticated')::text,false)`,
    [actor.auth_user_id]
  );

  const rows = (await client.query(`
    with mov as (
      select
        im.item_id::text as item_id,
        im.batch_id::text as batch_id,
        im.warehouse_id,
        sum(case when im.movement_type='purchase_in' and im.reference_table='purchase_receipts' then im.quantity else 0 end) as qty_received,
        sum(case when im.movement_type='return_out' and im.reference_table='purchase_returns' then im.quantity else 0 end) as qty_returned_purchase,
        sum(case when im.movement_type='sale_out' then im.quantity else 0 end) as qty_sold,
        sum(case when im.movement_type='wastage_out' then im.quantity else 0 end) as qty_wastage,
        sum(case when im.movement_type='adjust_out' then im.quantity else 0 end) as qty_adjust_out
      from public.inventory_movements im
      where im.batch_id is not null
      group by im.item_id::text, im.batch_id::text, im.warehouse_id
    )
    select
      m.item_id,
      mi.data->'name'->>'ar' as item_name,
      m.batch_id,
      w.name as warehouse_name,
      coalesce(b.quantity_received,0) as batch_received,
      coalesce(b.quantity_consumed,0) as batch_consumed,
      coalesce(b.quantity_transferred,0) as batch_transferred,
      greatest(coalesce(b.quantity_received,0)-coalesce(b.quantity_consumed,0)-coalesce(b.quantity_transferred,0),0) as batch_remaining,
      coalesce(m.qty_received,0) as received_in_movements,
      coalesce(m.qty_returned_purchase,0) as returned_purchase_qty,
      coalesce(m.qty_sold,0) as sold_qty,
      coalesce(m.qty_wastage,0) as wastage_qty,
      coalesce(m.qty_adjust_out,0) as adjust_out_qty
    from mov m
    left join public.batches b on b.id::text = m.batch_id
    left join public.menu_items mi on mi.id::text = m.item_id
    left join public.warehouses w on w.id = m.warehouse_id
    where coalesce(m.qty_returned_purchase,0) > 0
    order by coalesce(m.qty_returned_purchase,0) desc, item_name asc
  `)).rows;

  const out = {
    generated_at: new Date().toISOString(),
    total_batches_with_purchase_returns: rows.length,
    rows,
  };
  const outPath = path.join(process.cwd(), 'returned_batches_by_item_audit.json');
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
  console.log(outPath);
} finally {
  await client.end();
}
