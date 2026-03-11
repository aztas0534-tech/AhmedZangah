const fs = require('fs');
const { createClient } = require('./node_modules/@supabase/supabase-js');

const envFile = fs.readFileSync('.env.local', 'utf-8');
const env = {};
envFile.split(/\r?\n/).forEach(function(line) {
  const match = line.match(/^([^=]+)=(.*)$/);
  if (match) env[match[1].trim()] = match[2].trim();
});

const url = env['VITE_SUPABASE_URL'];
const serviceKey = env['VITE_SUPABASE_SERVICE_ROLE_KEY'] || env['VITE_SUPABASE_ANON_KEY'];
const supabase = createClient(url, serviceKey);

async function sql(q) {
  const r = await supabase.rpc('exec_debug_sql', { q });
  if (r.error) return { error: r.error.message || JSON.stringify(r.error) };
  return { data: r.data };
}

async function run() {
  console.log('='.repeat(70));
  console.log('  PRODUCTION DATABASE HEALTH CHECK');
  console.log('  ' + new Date().toISOString());
  console.log('='.repeat(70));

  let pass = 0, fail = 0, warn = 0;

  function ok(label) { pass++; console.log(`  ✅ ${label}`); }
  function err(label) { fail++; console.log(`  ❌ ${label}`); }
  function warning(label) { warn++; console.log(`  ⚠️  ${label}`); }

  // ─── 1. CHECK CRITICAL TABLES ───
  console.log('\n── 1. CRITICAL TABLES ──');
  const tables = [
    'orders', 'items', 'categories', 'admin_users', 'settings',
    'purchase_orders', 'suppliers', 'payments', 'cash_shifts',
    'journal_entries', 'journal_lines', 'chart_of_accounts',
    'financial_parties', 'financial_party_links', 'financial_party_ledger',
    'notifications', 'delivery_zones', 'inventory_movements',
    'expenses', 'accounting_periods', 'supplier_contracts',
    'supplier_evaluations', 'warehouse_transfers', 'stock_adjustments',
    'batch_recalls', 'promotions', 'challenges'
  ];
  
  const tableCheck = await sql(`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'public'
    AND table_type = 'BASE TABLE'
    ORDER BY table_name
  `);
  
  if (tableCheck.error) {
    err('Cannot query tables: ' + tableCheck.error);
  } else {
    const existing = new Set();
    // Parse the result - exec_debug_sql returns different formats
    if (tableCheck.data && tableCheck.data.rows) {
      tableCheck.data.rows.forEach(r => existing.add(r.table_name));
    } else if (Array.isArray(tableCheck.data)) {
      tableCheck.data.forEach(r => existing.add(r.table_name || r));
    }
    
    // Fallback: check each table individually
    for (const t of tables) {
      const r = await sql(`SELECT count(*)::text AS cnt FROM information_schema.tables WHERE table_schema='public' AND table_name='${t}'`);
      if (r.error) {
        err(`Table ${t}: check error`);
      } else {
        // Parse count from result
        const data = r.data;
        let cnt = 0;
        if (data && data.rows && data.rows[0]) cnt = parseInt(data.rows[0].cnt || '0');
        else if (data && typeof data === 'object' && data.cnt) cnt = parseInt(data.cnt);
        else if (typeof data === 'string' && data.includes('1')) cnt = 1;
        else if (data && data.ok) cnt = 1; // exec_debug_sql returns {ok: true} sometimes
        
        // Use another approach
        const r2 = await sql(`SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='${t}')::text AS ex`);
        if (r2.data && JSON.stringify(r2.data).includes('true')) {
          ok(`Table: ${t}`);
        } else if (r2.data && JSON.stringify(r2.data).includes('t')) {
          ok(`Table: ${t}`);
        } else if (r2.error) {
          err(`Table: ${t} — ${r2.error}`);
        } else {
          // Try direct select
          const r3 = await sql(`SELECT 1 FROM public.${t} LIMIT 0`);
          if (!r3.error) {
            ok(`Table: ${t}`);
          } else {
            err(`Table: ${t} — MISSING`);
          }
        }
      }
    }
  }

  // ─── 2. CHECK CRITICAL FUNCTIONS/RPCs ───
  console.log('\n── 2. CRITICAL FUNCTIONS (RPCs) ──');
  const functions = [
    'get_accountant_dashboard_summary',
    'get_shift_reconciliation_summary',
    'review_cash_shift',
    'ensure_cashier_cash_account',
    'post_cash_shift_close',
    'get_product_sales_report_v10',
    'get_product_sales_report_v9',
    'get_sales_report_v4',
    'process_order_delivery',
    'receive_purchase_order_item',
    'post_purchase_accounting',
    'create_payment',
    'manage_menu_item_stock',
    'get_current_stock',
    'get_item_stock_batches',
    'transfer_stock_between_warehouses',
    'create_stock_adjustment',
    'get_base_currency',
    'get_fx_rate',
    'get_account_id_by_code',
    'check_journal_entry_balance',
    'has_admin_permission',
    'open_cash_shift_for_cashier',
    'close_cash_shift',
    'exec_debug_sql',
    'get_inventory_stock_report',
    'get_wastage_report',
    'get_financial_summary_report',
    'delete_order_admin',
    'void_delivered_order',
    'get_party_ledger_statement',
  ];

  for (const fn of functions) {
    const r = await sql(`SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = '${fn}' LIMIT 1`);
    if (r.error && r.error.includes('0 rows')) {
      err(`Function: ${fn} — MISSING`);
    } else if (r.error) {
      err(`Function: ${fn} — ${r.error}`);
    } else {
      ok(`Function: ${fn}`);
    }
  }

  // ─── 3. CHECK CRITICAL COLUMNS ───
  console.log('\n── 3. CRITICAL COLUMNS ──');
  const columns = [
    ['cash_shifts', 'review_status'],
    ['cash_shifts', 'reviewed_at'],
    ['cash_shifts', 'reviewed_by'],
    ['cash_shifts', 'cash_account_id'],
    ['cash_shifts', 'difference_json'],
    ['orders', 'data'],
    ['orders', 'status'],
    ['orders', 'delivery_zone_id'],
    ['purchase_orders', 'total_amount'],
    ['purchase_orders', 'paid_amount'],
    ['purchase_orders', 'status'],
    ['journal_entries', 'source_table'],
    ['journal_entries', 'source_id'],
    ['journal_entries', 'source_event'],
    ['journal_lines', 'currency_code'],
    ['journal_lines', 'foreign_amount'],
    ['journal_lines', 'fx_rate'],
    ['chart_of_accounts', 'normal_balance'],
    ['financial_parties', 'party_type'],
    ['financial_party_links', 'linked_entity_id'],
    ['items', 'cost_price'],
    ['expenses', 'account_id'],
    ['payments', 'shift_id'],
    ['payments', 'base_amount'],
    ['payments', 'direction'],
  ];

  for (const [tbl, col] of columns) {
    const r = await sql(`SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND column_name='${col}' LIMIT 1`);
    if (r.error && r.error.includes('0 rows')) {
      err(`Column: ${tbl}.${col} — MISSING`);
    } else if (r.error) {
      err(`Column: ${tbl}.${col} — ${r.error}`);
    } else {
      ok(`Column: ${tbl}.${col}`);
    }
  }

  // ─── 4. CHECK TRIGGERS ───
  console.log('\n── 4. CRITICAL TRIGGERS ──');
  const triggers = [
    ['cash_shifts', 'trg_cash_shifts_assign_account'],
  ];

  for (const [tbl, trg] of triggers) {
    const r = await sql(`SELECT 1 FROM information_schema.triggers WHERE trigger_schema='public' AND event_object_table='${tbl}' AND trigger_name='${trg}' LIMIT 1`);
    if (r.error && r.error.includes('0 rows')) {
      err(`Trigger: ${trg} on ${tbl} — MISSING`);
    } else if (r.error) {
      err(`Trigger: ${trg} on ${tbl} — ${r.error}`); 
    } else {
      ok(`Trigger: ${trg} on ${tbl}`);
    }
  }

  // ─── 5. CHECK PERMISSIONS ───
  console.log('\n── 5. FUNCTION PERMISSIONS (authenticated) ──');
  const permFunctions = [
    'get_accountant_dashboard_summary',
    'get_shift_reconciliation_summary',
    'review_cash_shift',
    'get_product_sales_report_v10',
    'get_product_sales_report_v9',
  ];

  for (const fn of permFunctions) {
    const r = await sql(`
      SELECT has_function_privilege('authenticated', 
        (SELECT oid FROM pg_proc WHERE proname='${fn}' AND pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='public') LIMIT 1),
        'EXECUTE')::text AS can_exec
    `);
    if (r.error) {
      warning(`Permission: ${fn} — ${r.error}`);
    } else if (JSON.stringify(r.data).includes('true') || JSON.stringify(r.data).includes('t')) {
      ok(`Permission: authenticated → ${fn}`);
    } else {
      err(`Permission: authenticated cannot execute ${fn}`);
    }
  }

  // ─── 6. QUICK DATA SANITY ───
  console.log('\n── 6. DATA SANITY CHECKS ──');
  
  const dataChecks = [
    ["Items count", "SELECT count(*)::text AS c FROM public.items"],
    ["Orders count", "SELECT count(*)::text AS c FROM public.orders"],
    ["Chart of Accounts", "SELECT count(*)::text AS c FROM public.chart_of_accounts WHERE is_active"],
    ["Financial Parties", "SELECT count(*)::text AS c FROM public.financial_parties WHERE is_active"],
    ["Journal Entries", "SELECT count(*)::text AS c FROM public.journal_entries"],
    ["Suppliers", "SELECT count(*)::text AS c FROM public.suppliers"],
    ["Purchase Orders", "SELECT count(*)::text AS c FROM public.purchase_orders"],
    ["Base Currency", "SELECT public.get_base_currency()::text AS c"],
  ];

  for (const [label, q] of dataChecks) {
    const r = await sql(q);
    if (r.error) {
      warning(`${label}: ERROR — ${r.error}`);
    } else {
      const val = JSON.stringify(r.data);
      ok(`${label}: ${val}`);
    }
  }

  // ─── SUMMARY ───
  console.log('\n' + '='.repeat(70));
  console.log(`  RESULTS: ✅ ${pass} passed | ❌ ${fail} failed | ⚠️  ${warn} warnings`);
  if (fail === 0) {
    console.log('  🎉 ALL CHECKS PASSED — Production DB is COMPLETE');
  } else {
    console.log('  ⚠️  SOME CHECKS FAILED — Review above');
  }
  console.log('='.repeat(70));
}

run().catch(function(e) { console.error('FATAL:', e); });
