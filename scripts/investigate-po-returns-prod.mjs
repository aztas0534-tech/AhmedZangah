import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';

const password = String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim();
if (!password) throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');

const refs = ['PO-MAIN-2026-000002', 'PO-MAIN-2026-000003'];

const client = new Client({
  host: process.env.DB_HOST || 'aws-1-ap-south-1.pooler.supabase.com',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres.pmhivhtaoydfolseelyc',
  password,
  database: process.env.DB_NAME || 'postgres',
  ssl: { rejectUnauthorized: false },
});

const n = (v) => Number(v || 0) || 0;
const sum = (arr, pick) => arr.reduce((a, x) => a + n(pick(x)), 0);
const uniq = (arr) => Array.from(new Set(arr.filter(Boolean)));

const qJsonRows = async (sql, params = []) => {
  const r = await client.query(sql, params);
  return (r.rows || []).map((x) => x.row);
};

await client.connect();
const out = { generated_at: new Date().toISOString(), refs, resolved_orders: [], report: [] };
try {
  out.schema_checks = {};
  {
    const c = await client.query(`
      select table_name, array_agg(column_name order by ordinal_position) as cols
      from information_schema.columns
      where table_schema='public'
        and table_name in ('purchase_returns','purchase_return_items','purchase_receipts','inventory_movements')
      group by table_name
      order by table_name
    `);
    out.schema_checks.tables = c.rows || [];
    out.schema_checks.purchase_returns_has_status = (c.rows || []).some((r) => r.table_name === 'purchase_returns' && Array.isArray(r.cols) && r.cols.includes('status'));
  }

  out.reference_candidates = await qJsonRows(
    `
    select to_jsonb(po) as row
    from public.purchase_orders po
    where po.created_at >= '2026-01-01'::timestamptz
      and (
        po.reference_number ilike '%000002%'
        or po.reference_number ilike '%000003%'
        or abs(coalesce(po.total_amount,0) - 70515) < 0.01
        or abs(coalesce(po.base_total,0) - 70515) < 0.01
        or abs(coalesce(po.total_amount,0) - 164.75) < 0.01
        or abs(coalesce(po.base_total,0) - 164.75) < 0.01
      )
    order by po.created_at desc
    limit 30
    `
  );

  const orders = await qJsonRows(
    `
    select to_jsonb(po) as row
    from public.purchase_orders po
    where po.reference_number = any($1::text[])
       or po.po_number = any($1::text[])
       or po.reference_number ilike any(array['%000002%','%000003%'])
       or po.po_number ilike any(array['%000002%','%000003%'])
    order by po.created_at asc
    `,
    [refs]
  );
  out.resolved_orders = orders.map((o) => ({ id: o.id, reference_number: o.reference_number, status: o.status, created_at: o.created_at }));

  for (const po of orders) {
    const poId = String(po.id);
    const poRef = String(po.reference_number || poId);

    const items = await qJsonRows(`select to_jsonb(pi) as row from public.purchase_items pi where pi.purchase_order_id = $1 order by pi.created_at asc nulls last`, [poId]);
    const receipts = await qJsonRows(`select to_jsonb(pr) as row from public.purchase_receipts pr where pr.purchase_order_id = $1 order by pr.created_at asc nulls last`, [poId]);
    const receiptIds = uniq(receipts.map((r) => r.id));
    const receiptItems = receiptIds.length
      ? await qJsonRows(`select to_jsonb(pri) as row from public.purchase_receipt_items pri where pri.receipt_id = any($1::uuid[]) order by pri.created_at asc nulls last`, [receiptIds])
      : [];

    const returns = await qJsonRows(`select to_jsonb(pr) as row from public.purchase_returns pr where pr.purchase_order_id = $1 order by pr.created_at asc nulls last`, [poId]);
    const returnIds = uniq(returns.map((r) => r.id));
    const returnItems = returnIds.length
      ? await qJsonRows(`select to_jsonb(pri) as row from public.purchase_return_items pri where pri.return_id = any($1::uuid[]) order by pri.created_at asc nulls last`, [returnIds])
      : [];

    const movementsPo = await qJsonRows(
      `select to_jsonb(im) as row from public.inventory_movements im where im.reference_table='purchase_orders' and im.reference_id::text = $1 order by im.occurred_at asc nulls last, im.created_at asc nulls last`,
      [poId]
    );
    const movementsRet = returnIds.length
      ? await qJsonRows(
        `select to_jsonb(im) as row from public.inventory_movements im where im.reference_table='purchase_returns' and im.reference_id::text = any($1::text[]) order by im.occurred_at asc nulls last, im.created_at asc nulls last`,
        [returnIds.map(String)]
      )
      : [];
    const movementIds = uniq([...movementsPo, ...movementsRet].map((m) => m.id));

    const jePo = await qJsonRows(`select to_jsonb(je) as row from public.journal_entries je where je.source_table='purchase_orders' and je.source_id = $1 order by je.entry_date asc, je.created_at asc`, [poId]);
    const jeIm = movementIds.length
      ? await qJsonRows(`select to_jsonb(je) as row from public.journal_entries je where je.source_table='inventory_movements' and je.source_id = any($1::text[]) order by je.entry_date asc, je.created_at asc`, [movementIds.map(String)])
      : [];
    const payments = await qJsonRows(`select to_jsonb(p) as row from public.payments p where p.reference_table='purchase_orders' and p.reference_id::text = $1 order by p.occurred_at asc nulls last, p.created_at asc`, [poId]);
    const paymentIds = uniq(payments.map((p) => p.id));
    const jePay = paymentIds.length
      ? await qJsonRows(`select to_jsonb(je) as row from public.journal_entries je where je.source_table='payments' and je.source_id = any($1::text[]) order by je.entry_date asc, je.created_at asc`, [paymentIds.map(String)])
      : [];

    const allJeIds = uniq([...jePo, ...jeIm, ...jePay].map((j) => j.id));
    const jl = allJeIds.length
      ? await qJsonRows(
        `select to_jsonb(x) as row from (
          select jl.*, coa.code as account_code, coa.name as account_name
          from public.journal_lines jl
          left join public.chart_of_accounts coa on coa.id = jl.account_id
          where jl.journal_entry_id = any($1::uuid[])
          order by jl.created_at asc, jl.id asc
        ) x`,
        [allJeIds]
      )
      : [];

    const partyLedger = allJeIds.length
      ? await qJsonRows(`select to_jsonb(ple) as row from public.party_ledger_entries ple where ple.journal_entry_id = any($1::uuid[]) order by ple.occurred_at asc, ple.created_at asc`, [allJeIds])
      : [];

    const itemIds = uniq(items.map((i) => String(i.item_id || '')));
    const stockRows = itemIds.length
      ? await qJsonRows(`select to_jsonb(sm) as row from public.stock_management sm where sm.item_id::text = any($1::text[]) order by sm.item_id::text, sm.warehouse_id::text`, [itemIds])
      : [];

    const qtyOrdered = sum(items, (x) => x.qty_base ?? x.quantity);
    const qtyReceivedOnPoItems = sum(items, (x) => x.received_quantity);
    const qtyReceivedOnReceipts = sum(receiptItems, (x) => x.quantity ?? x.qty_base);
    const qtyReturnedByDocs = sum(returnItems, (x) => x.quantity ?? x.qty_base);
    const qtyReturnOutMovements = sum(movementsRet.filter((m) => String(m.movement_type) === 'return_out'), (x) => x.quantity ?? x.qty_base);
    const qtyPurchaseInMovements = sum(movementsPo.filter((m) => String(m.movement_type) === 'purchase_in'), (x) => x.quantity ?? x.qty_base);

    const returnExecution = returns.map((r) => {
      const rid = String(r.id);
      const ri = returnItems.filter((x) => String(x.return_id) === rid);
      const rm = movementsRet.filter((x) => String(x.reference_id) === rid && String(x.movement_type) === 'return_out');
      const qe = sum(ri, (x) => x.quantity ?? x.qty_base);
      const qm = sum(rm, (x) => x.quantity ?? x.qty_base);
      const completed = String(r.status || '').toLowerCase() === 'completed';
      const executed = qm > 0;
      const balanced = Math.abs(qe - qm) <= 0.0001;
      return {
        return_id: rid,
        status: r.status ?? null,
        returned_doc_qty: qe,
        return_out_qty: qm,
        movement_count: rm.length,
        completed,
        executed,
        balanced,
      };
    });

    const apImpactLines = jl.filter((x) => String(x.account_code || '') === '2010');
    const inventoryLines = jl.filter((x) => ['1300', '1310', '1320'].includes(String(x.account_code || '')) || String(x.account_name || '').toLowerCase().includes('inventory'));
    const returnMovementIds = movementsRet.filter((m) => String(m.movement_type) === 'return_out').map((m) => String(m.id));
    const jeReturn = jeIm.filter((j) => returnMovementIds.includes(String(j.source_id || '')));
    const jeReturnIds = uniq(jeReturn.map((j) => String(j.id)));
    const missingReturnMovementJEs = returnMovementIds.filter((mid) => !jeReturn.some((j) => String(j.source_id || '') === mid));
    const returnJeBalance = jeReturnIds.map((jid) => {
      const lines = jl.filter((x) => String(x.journal_entry_id || '') === jid);
      const debit = sum(lines, (x) => x.debit);
      const credit = sum(lines, (x) => x.credit);
      return { journal_entry_id: jid, lines: lines.length, debit, credit, balanced: Math.abs(debit - credit) <= 0.0001 };
    });

    out.report.push({
      purchase_order: po,
      metrics: {
        qty_ordered: qtyOrdered,
        qty_received_on_po_items: qtyReceivedOnPoItems,
        qty_received_on_receipts: qtyReceivedOnReceipts,
        qty_purchase_in_movements: qtyPurchaseInMovements,
        qty_returned_by_docs: qtyReturnedByDocs,
        qty_return_out_movements: qtyReturnOutMovements,
        return_docs_count: returns.length,
        return_execution_anomalies: returnExecution.filter((x) => (x.completed && !x.executed) || !x.balanced).length,
      },
      return_execution: returnExecution,
      receipts,
      receipt_items: receiptItems,
      returns,
      return_items: returnItems,
      movements_purchase_orders: movementsPo,
      movements_purchase_returns: movementsRet,
      payments,
      journal_entries_po: jePo,
      journal_entries_inventory_movements: jeIm,
      journal_entries_payments: jePay,
      journal_lines: jl,
      party_ledger_entries: partyLedger,
      stock_rows_for_items: stockRows,
      accounting_signals: {
        ap_lines_count: apImpactLines.length,
        inventory_lines_count: inventoryLines.length,
        return_out_movements_count: returnMovementIds.length,
        return_out_journal_entries_count: jeReturnIds.length,
        return_out_missing_journal_entries_count: missingReturnMovementJEs.length,
        return_out_unbalanced_journal_entries_count: returnJeBalance.filter((x) => !x.balanced).length,
      },
      return_journal_balance: returnJeBalance,
      verdict: {
        ref: poRef,
        claim_return_not_done_supported:
          returns.length === 0
            ? true
            : returnExecution.some((x) => (x.completed && !x.executed) || !x.balanced),
      },
    });
  }
} finally {
  await client.end();
}

const outPath = path.join(process.cwd(), 'backups', 'po_returns_investigation_prod.json');
fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
console.log(outPath);
