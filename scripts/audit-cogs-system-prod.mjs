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

await client.connect();
const out = {
  generated_at: new Date().toISOString(),
  range_days: 180,
  base_currency: null,
  rpc_availability: {},
  checks: {},
  samples: {},
};

try {
  {
    const r = await client.query(`select public.get_base_currency() as c`);
    out.base_currency = String(r.rows?.[0]?.c || 'YER').toUpperCase();
  }

  {
    const r = await client.query(`
      select
        to_regprocedure('public.get_sales_report_summary(timestamptz,timestamptz,uuid,boolean)') is not null as has_sales_summary,
        to_regprocedure('public.get_product_sales_report_v10(timestamptz,timestamptz,uuid,boolean)') is not null as has_product_v10,
        to_regprocedure('public.get_product_sales_report_v9(timestamptz,timestamptz,uuid,boolean)') is not null as has_product_v9,
        to_regprocedure('public.audit_sales_cogs(timestamptz,timestamptz)') is not null as has_audit_sales_cogs
    `);
    out.rpc_availability = r.rows?.[0] || {};
  }

  {
    const r = await client.query(`
      with range_orders as (
        select o.id, o.currency, o.fx_rate, o.status, o.data, o.created_at
        from public.orders o
        where o.created_at >= now() - interval '180 days'
          and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
      ),
      delivered as (
        select * from range_orders where status='delivered'
      ),
      oic as (
        select order_id, sum(coalesce(total_cost,0)) as cogs
        from public.order_item_cogs
        group by order_id
      ),
      mv as (
        select (reference_id)::uuid as order_id,
               sum(coalesce(nullif(total_cost,0), quantity*coalesce(nullif(unit_cost,0),0),0)) as mv_cogs
        from public.inventory_movements
        where reference_table='orders' and movement_type='sale_out'
          and occurred_at >= now() - interval '180 days'
        group by (reference_id)::uuid
      )
      select
        (select count(*) from delivered)::int as delivered_orders,
        (select count(*) from delivered d where upper(coalesce(d.currency,'')) <> upper($1))::int as delivered_non_base_currency_orders,
        (select count(*) from delivered d where upper(coalesce(d.currency,'')) <> upper($1) and coalesce(d.fx_rate,0) <= 0)::int as delivered_non_base_missing_fx,
        (select count(*) from delivered d left join oic on oic.order_id=d.id where oic.order_id is null)::int as delivered_missing_oic,
        (select count(*) from delivered d left join oic on oic.order_id=d.id where oic.order_id is not null and coalesce(oic.cogs,0)<=0)::int as delivered_zero_oic,
        (select count(*) from delivered d left join mv on mv.order_id=d.id where mv.order_id is null)::int as delivered_missing_sale_out_mv,
        (select count(*) from delivered d left join oic on oic.order_id=d.id left join mv on mv.order_id=d.id where oic.order_id is not null and mv.order_id is not null and abs(coalesce(oic.cogs,0)-coalesce(mv.mv_cogs,0)) > 0.01)::int as delivered_oic_mv_mismatch
    `, [out.base_currency]);
    out.checks.coverage = r.rows?.[0] || {};
  }

  {
    const r = await client.query(`
      with delivered as (
        select o.id
        from public.orders o
        where o.status='delivered'
          and o.created_at >= now() - interval '180 days'
          and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
      ),
      oic as (
        select order_id, sum(coalesce(total_cost,0)) as cogs, sum(coalesce(quantity,0)) as qty, count(*) as rows
        from public.order_item_cogs
        group by order_id
      ),
      mv as (
        select (reference_id)::uuid as order_id,
               sum(coalesce(nullif(total_cost,0), quantity*coalesce(nullif(unit_cost,0),0),0)) as mv_cogs,
               sum(coalesce(quantity,0)) as qty,
               count(*) as rows
        from public.inventory_movements
        where reference_table='orders' and movement_type='sale_out'
          and occurred_at >= now() - interval '180 days'
        group by (reference_id)::uuid
      )
      select
        d.id::text as order_id,
        coalesce(oic.rows,0) as oic_rows,
        coalesce(oic.qty,0) as oic_qty,
        coalesce(oic.cogs,0) as oic_cogs,
        coalesce(mv.rows,0) as mv_rows,
        coalesce(mv.qty,0) as mv_qty,
        coalesce(mv.mv_cogs,0) as mv_cogs,
        (coalesce(oic.cogs,0)-coalesce(mv.mv_cogs,0)) as delta
      from delivered d
      left join oic on oic.order_id=d.id
      left join mv on mv.order_id=d.id
      where oic.order_id is not null and mv.order_id is not null
        and abs(coalesce(oic.cogs,0)-coalesce(mv.mv_cogs,0)) > 0.01
      order by abs(coalesce(oic.cogs,0)-coalesce(mv.mv_cogs,0)) desc
      limit 30
    `);
    out.samples.oic_vs_movement_mismatch_top30 = r.rows || [];
  }

  {
    const r = await client.query(`
      with returns_range as (
        select sr.id, sr.order_id
        from public.sales_returns sr
        where sr.status='completed'
          and sr.return_date >= now() - interval '180 days'
      ),
      ret_mv as (
        select sum(coalesce(im.total_cost,0)) as return_in_cost
        from public.inventory_movements im
        where im.reference_table='sales_returns'
          and im.movement_type='return_in'
          and im.occurred_at >= now() - interval '180 days'
      ),
      ret_je as (
        select
          sum(case when coa.code='5010' then coalesce(jl.credit,0) else 0 end) as cogs_credit,
          sum(case when coa.code='1410' then coalesce(jl.debit,0) else 0 end) as inventory_debit
        from public.journal_entries je
        join public.journal_lines jl on jl.journal_entry_id=je.id
        left join public.chart_of_accounts coa on coa.id=jl.account_id
        where je.source_table='inventory_movements'
          and je.source_event='return_in'
          and je.entry_date >= now() - interval '180 days'
      )
      select
        (select count(*)::int from returns_range) as completed_sales_returns,
        coalesce((select return_in_cost from ret_mv),0) as return_in_cost_movements,
        coalesce((select cogs_credit from ret_je),0) as return_in_cogs_credit_journal,
        coalesce((select inventory_debit from ret_je),0) as return_in_inventory_debit_journal
    `);
    out.checks.sales_returns_cogs = r.rows?.[0] || {};
  }

  if (out.rpc_availability.has_sales_summary) {
    try {
      const r = await client.query(`
        select public.get_sales_report_summary(now() - interval '180 days', now(), null, false) as j
      `);
      const j = r.rows?.[0]?.j || {};
      out.checks.sales_summary_rpc = {
        cogs: n(j.cogs),
        returns_cogs: n(j.returns_cogs),
        total_orders: n(j.total_orders),
        delivered_orders: n(j.delivered_orders),
      };
    } catch (e) {
      out.checks.sales_summary_rpc_error = String(e?.message || e || '');
    }
  }

  {
    const r = await client.query(`
      with eligible_orders as (
        select o.id
        from public.orders o
        where o.created_at >= now() - interval '180 days'
          and (o.status='delivered' or nullif(o.data->>'paidAt','') is not null)
          and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
      ),
      cogs_oic as (
        select coalesce(sum(oic.total_cost),0) as v
        from public.order_item_cogs oic
        join eligible_orders eo on eo.id=oic.order_id
      ),
      cogs_mv as (
        select coalesce(sum(coalesce(nullif(im.total_cost,0), im.quantity * coalesce(nullif(b.unit_cost,0), nullif(im.unit_cost,0), 0))),0) as v
        from public.inventory_movements im
        left join public.batches b on b.id=im.batch_id
        join eligible_orders eo on eo.id::text=im.reference_id
        where im.reference_table='orders' and im.movement_type='sale_out'
      ),
      returns_mv as (
        select coalesce(sum(coalesce(nullif(im.total_cost,0), im.quantity * coalesce(nullif(b.unit_cost,0), nullif(im.unit_cost,0), 0))),0) as v
        from public.inventory_movements im
        left join public.batches b on b.id=im.batch_id
        where im.reference_table='sales_returns'
          and im.movement_type='return_in'
          and im.occurred_at >= now() - interval '180 days'
      )
      select
        (select v from cogs_oic) as oic_cogs,
        (select v from cogs_mv) as movement_cogs,
        (select v from returns_mv) as returns_cogs
    `);
    out.checks.cross_source_totals = r.rows?.[0] || {};
  }

  if (out.rpc_availability.has_product_v10 || out.rpc_availability.has_product_v9) {
    const one = async (name) => {
      const q = `select * from public.${name}(now() - interval '180 days', now(), null, false)`;
      const r = await client.query(q);
      const rows = r.rows || [];
      return {
        rows: rows.length,
        total_sales: rows.reduce((s, x) => s + n(x.total_sales), 0),
        total_cost: rows.reduce((s, x) => s + n(x.total_cost), 0),
        total_qty: rows.reduce((s, x) => s + n(x.quantity_sold), 0),
      };
    };
    if (out.rpc_availability.has_product_v10) {
      try {
        out.checks.product_report_v10 = await one('get_product_sales_report_v10');
      } catch (e) {
        out.checks.product_report_v10_error = String(e?.message || e || '');
      }
    }
    if (out.rpc_availability.has_product_v9) {
      try {
        out.checks.product_report_v9 = await one('get_product_sales_report_v9');
      } catch (e) {
        out.checks.product_report_v9_error = String(e?.message || e || '');
      }
    }
  }

  {
    const r = await client.query(`
      select
        count(*)::int as sale_out_rows_non_base_orders,
        count(*) filter (where je.id is null)::int as non_base_sale_out_missing_journal_entry,
        count(*) filter (where je.currency_code is null and upper(coalesce(o.currency,'')) <> upper($1))::int as non_base_sale_out_missing_fx_meta,
        count(*) filter (where upper(coalesce(o.currency,'')) <> upper($1) and coalesce(je.fx_rate,0) <= 0)::int as non_base_sale_out_invalid_fx_meta
      from public.inventory_movements im
      join public.orders o on o.id::text=im.reference_id
      left join public.journal_entries je on je.source_table='inventory_movements' and je.source_id=im.id::text and je.source_event='sale_out'
      where im.reference_table='orders'
        and im.movement_type='sale_out'
        and im.occurred_at >= now() - interval '180 days'
        and upper(coalesce(o.currency,'')) <> upper($1)
    `, [out.base_currency]);
    out.checks.sale_out_fx_metadata = r.rows?.[0] || {};
  }

  {
    const r = await client.query(`
      with ret_mv as (
        select im.id::text as movement_id
        from public.inventory_movements im
        where im.reference_table='sales_returns'
          and im.movement_type='return_in'
          and im.occurred_at >= now() - interval '180 days'
      ),
      ret_je as (
        select je.source_id as movement_id, count(*) as je_count
        from public.journal_entries je
        where je.source_table='inventory_movements'
          and je.source_event='return_in'
        group by je.source_id
      )
      select
        (select count(*)::int from ret_mv) as return_in_movements_count,
        (select count(*)::int from ret_je) as return_in_journal_entries_count,
        (select count(*)::int from ret_mv rm left join ret_je rj on rj.movement_id=rm.movement_id where rj.movement_id is null) as return_in_without_journal,
        (select count(*)::int from ret_je where je_count > 1) as return_in_with_duplicate_journal
    `);
    out.checks.return_in_posting_integrity = r.rows?.[0] || {};
  }

  if (out.rpc_availability.has_audit_sales_cogs) {
    try {
      const r = await client.query(`select public.audit_sales_cogs(now() - interval '180 days', now()) as j`);
      out.checks.audit_sales_cogs_rpc = r.rows?.[0]?.j || {};
    } catch (e) {
      out.checks.audit_sales_cogs_rpc_error = String(e?.message || e || '');
    }
  }
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'backups', 'cogs_system_audit_prod.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
