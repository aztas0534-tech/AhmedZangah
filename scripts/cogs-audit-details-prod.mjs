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
const out = { generated_at: new Date().toISOString() };
try {
  {
    const r = await client.query(`
      with ret_mv as (
        select im.id, im.reference_id, im.item_id, im.quantity, im.total_cost, im.occurred_at, im.data
        from public.inventory_movements im
        where im.reference_table='sales_returns'
          and im.movement_type='return_in'
          and im.occurred_at >= now() - interval '180 days'
      )
      select
        rm.id::text as movement_id,
        rm.reference_id as sales_return_id,
        coalesce(rm.data->>'orderId','') as order_id,
        rm.item_id::text as item_id,
        rm.quantity,
        rm.total_cost,
        rm.occurred_at
      from ret_mv rm
      left join public.journal_entries je
        on je.source_table='inventory_movements'
       and je.source_event='return_in'
       and je.source_id=rm.id::text
      where je.id is null
      order by rm.occurred_at desc
      limit 50
    `);
    out.return_in_without_journal = r.rows || [];
  }

  {
    const r = await client.query(`
      select
        im.id::text as movement_id,
        o.id::text as order_id,
        o.status as order_status,
        o.currency as order_currency,
        o.fx_rate as order_fx_rate,
        im.occurred_at
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id
      left join public.journal_entries je
        on je.source_table='inventory_movements'
       and je.source_event='sale_out'
       and je.source_id=im.id::text
      where im.reference_table='orders'
        and im.movement_type='sale_out'
        and im.occurred_at >= now() - interval '180 days'
        and upper(coalesce(o.currency,'')) <> upper(public.get_base_currency())
        and je.id is null
      order by im.occurred_at desc
      limit 80
    `);
    out.non_base_sale_out_without_journal = r.rows || [];
  }
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'backups', 'cogs_system_audit_details_prod.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
