import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || '').trim();
if (!password) throw new Error('DBPW required');

const client = new Client({
  host: 'aws-1-ap-south-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
});

const itemIds = [
  '47958139-0dfc-43ff-b2d0-e927a91f8125',
  '483e5961-7840-44b0-a5d5-35bf4d3fc26f',
];

await client.connect();
const out = { generated_at: new Date().toISOString(), dry_run: [], applied: [] };
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

  const wh = (await client.query(`
    select warehouse_id::text as warehouse_id
    from public.stock_management
    where item_id::text = $1
    order by available_quantity desc nulls last
    limit 1
  `, [itemIds[0]])).rows[0]?.warehouse_id || null;

  for (const itemId of itemIds) {
    const d = (await client.query(
      `select public.repair_item_purchase_costs($1::text,$2::uuid,$3::boolean) as r`,
      [itemId, wh, true]
    )).rows[0]?.r;
    out.dry_run.push({ item_id: itemId, result: d });
  }

  for (const itemId of itemIds) {
    const a = (await client.query(
      `select public.repair_item_purchase_costs($1::text,$2::uuid,$3::boolean) as r`,
      [itemId, wh, false]
    )).rows[0]?.r;
    out.applied.push({ item_id: itemId, result: a });
  }
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_specific_items_purchase_cost_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
