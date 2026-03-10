import { Client } from 'pg';

const password = String(process.env.DBPW || '').trim();
if (!password) throw new Error('DBPW required');

const c = new Client({
  host: 'aws-1-ap-south-1.pooler.supabase.com',
  port: 5432,
  user: 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
});

await c.connect();
try {
  const actor = (await c.query(`
    select auth_user_id
    from public.admin_users
    where is_active = true
    order by (case when role='owner' then 1 else 0 end) desc, created_at asc nulls last
    limit 1
  `)).rows[0];
  await c.query(
    `select
      set_config('request.jwt.claim.sub',$1::text,false),
      set_config('request.jwt.claim.role','authenticated',false),
      set_config('request.jwt.claims',json_build_object('sub',$1::text,'role','authenticated')::text,false)`,
    [actor.auth_user_id]
  );

  const itemId = '47958139-0dfc-43ff-b2d0-e927a91f8125';
  const r = await c.query(`
    with b as (
      select b.id as batch_id, b.warehouse_id, b.receipt_id
      from public.batches b
      where b.item_id::text = $1
    ),
    avg as (
      select
        pr.id as receipt_id,
        bb.warehouse_id,
        case
          when sum(coalesce(pi.qty_base,0)) > 0 then
            sum(coalesce(pi.qty_base,0) * coalesce(nullif(pi.unit_cost_base,0),0))
            / sum(coalesce(pi.qty_base,0))
          else max(coalesce(nullif(pi.unit_cost_base,0),0))
        end as goods_unit_cost_base
      from b bb
      join public.purchase_receipts pr on pr.id = bb.receipt_id
      join public.purchase_items pi on pi.purchase_order_id = pr.purchase_order_id and pi.item_id::text = $1
      group by pr.id, bb.warehouse_id
    )
    select
      bb.batch_id::text,
      bb.warehouse_id::text,
      pri.id::text as pri_id,
      pri.unit_cost as pri_unit_cost,
      avg.goods_unit_cost_base as expected,
      abs(coalesce(pri.unit_cost,0)-coalesce(avg.goods_unit_cost_base,0)) as diff
    from b bb
    join public.purchase_receipt_items pri on pri.receipt_id = bb.receipt_id and pri.item_id::text=$1
    join avg on avg.receipt_id = bb.receipt_id and avg.warehouse_id = bb.warehouse_id
    order by diff desc
  `, [itemId]);
  console.log(JSON.stringify(r.rows, null, 2));
} finally {
  await c.end();
}
