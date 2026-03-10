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
  '88341c63-94c9-4a4c-87cc-e875fd573d03',
  '483e5961-7840-44b0-a5d5-35bf4d3fc26f',
  '47958139-0dfc-43ff-b2d0-e927a91f8125',
];

await client.connect();
const out = {
  generated_at: new Date().toISOString(),
  batches_revalued: [],
  oic_rows_deleted: 0,
  oic_rows_inserted: 0,
};

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
      set_config('request.jwt.claims',json_build_object('sub',$1::text,'role','authenticated')::text,false),
      set_config('app.allow_ledger_ddl','1',false)`,
    [actor.auth_user_id]
  );

  const badBatches = (await client.query(`
    select
      b.id::text as batch_id,
      b.item_id::text as item_id,
      b.unit_cost as old_unit_cost,
      coalesce(
        (
          select max(coalesce(pi.unit_cost_base,0))
          from public.purchase_items pi
          join public.purchase_receipts pr on pr.purchase_order_id = pi.purchase_order_id
          where pr.id = b.receipt_id
            and pi.item_id::text = b.item_id::text
            and coalesce(pi.unit_cost_base,0) > 0
        ),
        b.unit_cost
      ) as expected_unit_cost
    from public.batches b
    where b.item_id::text = any($1::text[])
      and coalesce(b.status,'active')='active'
      and coalesce(b.foreign_currency,'')='YER'
      and coalesce(b.unit_cost,0) < 1
  `, [itemIds])).rows;
  const overrideUnitCost = new Map(
    badBatches
      .filter((b) => Number(b.expected_unit_cost || 0) > 0)
      .map((b) => [String(b.batch_id), Number(b.expected_unit_cost)])
  );

  for (const b of badBatches) {
    if (Number(b.expected_unit_cost || 0) <= 0) continue;
    if (Math.abs(Number(b.expected_unit_cost) - Number(b.old_unit_cost || 0)) <= 0.01) continue;
    try {
      const r = (await client.query(
        `select public.revalue_batch_unit_cost($1::uuid,$2::numeric,$3::text,$4::boolean) as r`,
        [b.batch_id, b.expected_unit_cost, 'targeted_two_cases_fx_fix', true]
      )).rows[0]?.r;
      out.batches_revalued.push(r);
    } catch (e) {
      out.batches_revalued.push({
        batchId: b.batch_id,
        oldUnitCost: b.old_unit_cost,
        newUnitCost: b.expected_unit_cost,
        error: String(e?.message || e),
      });
    }
  }

  const saleMoves = (await client.query(`
    select
      im.reference_id as order_id_text,
      im.item_id::text as item_id_text,
      im.batch_id::text as batch_id_text,
      coalesce(im.quantity,0) as qty,
      coalesce(b.unit_cost, im.unit_cost, 0) as base_unit_cost
    from public.inventory_movements im
    left join public.batches b on b.id = im.batch_id
    where im.reference_table='orders'
      and im.movement_type='sale_out'
      and im.item_id::text = any($1::text[])
      and im.reference_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  `, [itemIds])).rows;

  const aggregate = new Map();
  for (const m of saleMoves) {
    const key = `${m.order_id_text}|${m.item_id_text}`;
    const unit = overrideUnitCost.get(String(m.batch_id_text)) ?? Number(m.base_unit_cost || 0);
    const qty = Number(m.qty || 0);
    const row = aggregate.get(key) || {
      order_id_text: String(m.order_id_text),
      item_id_text: String(m.item_id_text),
      qty: 0,
      corrected_total_cost: 0,
    };
    row.qty += qty;
    row.corrected_total_cost += qty * unit;
    aggregate.set(key, row);
  }
  const rebuildRows = [...aggregate.values()]
    .filter((r) => r.qty > 0)
    .map((r) => ({
      ...r,
      corrected_unit_cost: r.corrected_total_cost / r.qty,
    }));

  if (rebuildRows.length) {
    const orderIds = [...new Set(rebuildRows.map((r) => String(r.order_id_text)))];
    const delRes = await client.query(
      `delete from public.order_item_cogs
       where order_id::text = any($1::text[])
         and item_id::text = any($2::text[])`,
      [orderIds, itemIds]
    );
    out.oic_rows_deleted = delRes.rowCount || 0;

    let inserted = 0;
    for (const r of rebuildRows) {
      await client.query(
        `insert into public.order_item_cogs(order_id,item_id,quantity,unit_cost,total_cost,created_at)
         values ($1::uuid,$2,$3,$4,$5,now())`,
        [String(r.order_id_text), String(r.item_id_text), Number(r.qty || 0), Number(r.corrected_unit_cost || 0), Number(r.corrected_total_cost || 0)]
      );
      inserted += 1;
    }
    out.oic_rows_inserted = inserted;
  }
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'repair_two_cases_targeted_result.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
