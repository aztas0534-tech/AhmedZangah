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

const n = (v) => Number(v || 0) || 0;
const r2 = (v) => Math.round((n(v) + Number.EPSILON) * 100) / 100;

await client.connect();
const out = {
  generated_at: new Date().toISOString(),
  affected_items: [],
  candidate_movements: 0,
  repaired_entries: 0,
  skipped: 0,
  total_abs_delta: 0,
  samples: [],
};

try {
  const actor = (await client.query(`
    select auth_user_id
    from public.admin_users
    where is_active = true
    order by (case when role='owner' then 1 else 0 end) desc, created_at asc nulls last
    limit 1
  `)).rows[0];
  if (!actor?.auth_user_id) throw new Error('No active admin user');

  await client.query(
    `select
      set_config('request.jwt.claim.sub', $1::text, false),
      set_config('request.jwt.claim.role', 'authenticated', false),
      set_config('request.jwt.claims', json_build_object('sub',$1::text,'role','authenticated')::text, false),
      set_config('app.allow_ledger_ddl', '1', false)`,
    [actor.auth_user_id]
  );

  const reportRows = (await client.query(
    `select item_id,total_sales,total_cost,quantity_sold
     from public.get_product_sales_report_v9($1::timestamptz,$2::timestamptz,$3::uuid,$4::boolean)`,
    ['1970-01-01T00:00:00.000Z', new Date().toISOString(), null, false]
  )).rows;

  out.affected_items = reportRows
    .filter((r) => {
      const sales = n(r.total_sales);
      const cost = n(r.total_cost);
      const qty = n(r.quantity_sold);
      return (sales > 0 && cost === 0) || (cost > sales + 0.01) || (sales > 0 && qty <= 0) || (sales > 0 && (cost / sales) > 1.5);
    })
    .map((r) => String(r.item_id));

  if (!out.affected_items.length) {
    const outPath = path.join(process.cwd(), 'product_anomalies_stage3_ledger_repair.json');
    fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
    console.log(outPath);
    process.exit(0);
  }

  const accounts = (await client.query(`
    select
      public.get_account_id_by_code('1410') as inventory_account,
      public.get_account_id_by_code('5010') as cogs_account
  `)).rows[0];
  const inventoryAccount = accounts?.inventory_account;
  const cogsAccount = accounts?.cogs_account;
  if (!inventoryAccount || !cogsAccount) throw new Error('Missing required accounts 1410/5010');

  const moves = (await client.query(
    `with target as (
       select unnest($1::text[]) as item_id
     ),
     mv as (
       select
         im.id as movement_id,
         im.item_id::text as item_id,
         im.movement_type,
         im.total_cost as movement_total,
         im.warehouse_id,
         je.id as source_entry_id
       from public.inventory_movements im
       left join public.journal_entries je
         on je.source_table='inventory_movements'
        and je.source_id=im.id::text
        and coalesce(je.status,'')='posted'
       where im.item_id::text in (select item_id from target)
         and im.movement_type in ('sale_out','return_in')
     ),
     jl as (
       select
         m.*,
         coalesce(greatest(sum(jl.debit), sum(jl.credit)), 0) as posted_total
       from mv m
       left join public.journal_lines jl on jl.journal_entry_id = m.source_entry_id
       group by m.movement_id, m.item_id, m.movement_type, m.movement_total, m.warehouse_id, m.source_entry_id
     )
     select
       movement_id,
       item_id,
       movement_type,
       movement_total,
       posted_total,
       public._money_round(coalesce(movement_total,0) - coalesce(posted_total,0)) as delta,
       warehouse_id
     from jl
     where abs(public._money_round(coalesce(movement_total,0) - coalesce(posted_total,0))) > 0.01
     order by abs(public._money_round(coalesce(movement_total,0) - coalesce(posted_total,0))) desc`,
    [out.affected_items]
  )).rows;

  out.candidate_movements = moves.length;
  out.total_abs_delta = r2(moves.reduce((s, m) => s + Math.abs(n(m.delta)), 0));

  for (const m of moves) {
    await client.query('begin');
    try {
      const repairSource = (await client.query(
        `select public.uuid_from_text($1) as id`,
        [`cogsfix:stage3:${String(m.movement_id)}`]
      )).rows[0]?.id;

      const already = (await client.query(
        `select 1
         from public.journal_entries
         where source_table='ledger_repairs'
           and source_id=$1::text
           and source_event='fix_sale_out_cogs_stage3'
         limit 1`,
        [repairSource]
      )).rowCount > 0;

      if (already) {
        out.skipped += 1;
        await client.query('rollback');
        continue;
      }

      const branchCompany = (await client.query(
        `select
           coalesce(public.branch_from_warehouse($1::uuid), public.get_default_branch_id()) as branch_id,
           coalesce(public.company_from_branch(coalesce(public.branch_from_warehouse($1::uuid), public.get_default_branch_id())), public.get_default_company_id()) as company_id`,
        [m.warehouse_id]
      )).rows[0] || {};

      const entry = (await client.query(
        `insert into public.journal_entries(
           entry_date, memo, source_table, source_id, source_event, created_by, status, branch_id, company_id
         )
         values (
           now(),
           $1::text,
           'ledger_repairs',
           $2::text,
           'fix_sale_out_cogs_stage3',
           auth.uid(),
           'posted',
           $3::uuid,
           $4::uuid
         )
         returning id`,
        [
          `Stage3 COGS repair movement ${String(m.movement_id)}`,
          String(repairSource),
          branchCompany.branch_id || null,
          branchCompany.company_id || null,
        ]
      )).rows[0];

      const delta = n(m.delta);
      if (String(m.movement_type) === 'return_in') {
        if (delta > 0) {
          await client.query(
            `insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
             values
             ($1::uuid,$2::uuid,$3::numeric,0,'Stage3 return_in inventory restore'),
             ($1::uuid,$4::uuid,0,$3::numeric,'Stage3 return_in cogs reverse')`,
            [entry.id, inventoryAccount, Math.abs(delta), cogsAccount]
          );
        } else {
          await client.query(
            `insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
             values
             ($1::uuid,$4::uuid,$3::numeric,0,'Stage3 return_in cogs reverse'),
             ($1::uuid,$2::uuid,0,$3::numeric,'Stage3 return_in inventory restore')`,
            [entry.id, inventoryAccount, Math.abs(delta), cogsAccount]
          );
        }
      } else {
        if (delta > 0) {
          await client.query(
            `insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
             values
             ($1::uuid,$2::uuid,$3::numeric,0,'Stage3 cogs increase'),
             ($1::uuid,$4::uuid,0,$3::numeric,'Stage3 inventory decrease')`,
            [entry.id, cogsAccount, Math.abs(delta), inventoryAccount]
          );
        } else {
          await client.query(
            `insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
             values
             ($1::uuid,$4::uuid,$3::numeric,0,'Stage3 inventory increase'),
             ($1::uuid,$2::uuid,0,$3::numeric,'Stage3 cogs decrease')`,
            [entry.id, cogsAccount, Math.abs(delta), inventoryAccount]
          );
        }
      }

      await client.query(`select public.check_journal_entry_balance($1::uuid)`, [entry.id]);
      await client.query('commit');
      out.repaired_entries += 1;
      if (out.samples.length < 15) {
        out.samples.push({
          movement_id: String(m.movement_id),
          item_id: String(m.item_id),
          movement_type: String(m.movement_type),
          delta: r2(delta),
          journal_entry_id: String(entry.id),
        });
      }
    } catch (e) {
      await client.query('rollback');
      out.skipped += 1;
      if (out.samples.length < 15) {
        out.samples.push({
          movement_id: String(m.movement_id),
          item_id: String(m.item_id),
          movement_type: String(m.movement_type),
          error: String(e?.message || e),
        });
      }
    }
  }
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'product_anomalies_stage3_ledger_repair.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
