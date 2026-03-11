import fs from 'fs';

const missingDataColsList = `admin_users, product_prices_multi_currency, workflow_delegations, workflow_escalation_rules, approval_policy_steps, pricing_rpc_logs, batch_prices_multi_currency, _temp_historical_repair_results, hr_leave_types, hr_leave_requests, hr_leave_balances, payroll_attendance, fx_rate_audit_log, payroll_run_lines, system_alerts, chart_of_accounts, payroll_settings, payroll_employees, party_balance_snapshots, financial_parties, financial_party_links, party_subledger_accounts, inventory_counts, party_credit_overrides, purchase_return_items, notifications, cost_centers, payroll_loans, warehouses, accounting_light_entries, accounting_period_snapshots, approval_policies, import_expenses, approval_steps, supplier_invoices, three_way_match_results, invoice_tolerances, batch_recalls, ledger_lines, journal_entries, tax_jurisdictions, inventory_count_items, job_runs, approval_requests, tax_rates, item_tax_profiles, fx_revaluation_monetary_audit, uom, uom_conversions, item_uom, job_schedules, party_ledger_entries, sales_returns, attendance_config, purchase_receipt_items, party_documents, journal_lines, import_shipments, party_open_items, attendance_punches, ledger_entry_hash_chain, currencies, fx_rates, purchase_orders, purchase_receipt_expenses, party_currencies, reservation_lines, payroll_run_party_settlements, document_sequences, stock_wastage, ar_open_items, supplier_credit_notes, ledger_entry_signatures, ar_allocations, supplier_credit_note_allocations, settlement_lines, open_item_snapshots, item_uom_units, bank_accounts, bank_statement_batches, bank_statement_lines, bank_reconciliation_matches, order_events, order_item_cogs, batch_reservations, batch_sales_trace, order_tax_lines, promotion_usage, cod_settlement_orders, ar_payment_status, order_item_reservations, accounting_periods, production_orders, production_order_inputs, party_credit_limits, production_order_outputs, payroll_rule_defs, payroll_tax_defs, budget_scenarios, budget_headers, budget_lines, purchase_receipts, warehouse_transfers, batch_balances, pos_offline_sales, inventory_transfers, purchase_items, purchase_returns, warehouse_transfer_items, import_shipments_items, inventory_transfer_items, qc_checks, import_shipment_purchase_orders, projects, ledger_snapshot_lines, departments, journals, customer_special_prices, customer_tax_profiles, supplier_evaluations, supplier_contracts, settlement_headers, consolidation_intercompany_parties, product_audit_log, ledger_audit_log, supplier_invoice_lines, accounting_job_schedules, accounting_job_failures, accounting_job_metrics, accounting_job_dead_letters, ledger_snapshot_headers, companies, branches, workflow_instances, consolidation_groups, consolidation_group_members, workflow_approvals, intercompany_elimination_rules, consolidation_elimination_accounts, consolidation_unrealized_profit_rules, consolidation_snapshot_headers, workflow_event_logs, workflow_step_assignments, promotion_items, consolidation_snapshot_lines, workflow_definitions, workflow_rules, cash_shifts, accounting_jobs, driver_ledger, fx_revaluation_audit, landed_cost_audit, system_audit_logs, supplier_items, suppliers, payroll_runs, price_tiers, ledger_public_keys, base_currency_migration_entry_map, base_currency_migration_state, base_currency_restatement_state, base_currency_restatement_entry_map, base_currency_restatement_batch_audit, base_currency_restatement_batch_audit_v2`;

const missingTables = missingDataColsList.split(',').map(s => s.trim());
console.log('Total missing data cols tables:', missingTables.length);

const schemaStr = fs.readFileSync('tmp_local_schema.sql', 'utf8');

// split into statements by semicolon, naive approach
const statements = schemaStr.split(';');

let results = [];
for (let i = 0; i < statements.length; i++) {
  const stmt = statements[i].toLowerCase();
  
  if (stmt.includes(' data ') || stmt.includes(' data=') || stmt.includes('(data') || stmt.includes('.data') || stmt.includes('data->')) {
    // If it mentions data, let's see if it explicitly operates on a missing table
    for (const t of missingTables) {
      if (stmt.includes(' ' + t) || stmt.includes('"' + t + '"')) {
        // It might be a match!
        // Ignore if it ALSO contains a valid table with data
        let hasValidTable = false;
        if (stmt.includes('orders') || stmt.includes('batches') || stmt.includes('inventory_movements') || stmt.includes('stock_management') || stmt.includes('app_settings')) {
            hasValidTable = true;
        }

        if (!hasValidTable) {
           results.push({ table: t, stmt: stmt.trim().substring(0, 150) + '...' });
        }
      }
    }
  }
}

console.log("Found matches:");
console.log(JSON.stringify(results, null, 2));

