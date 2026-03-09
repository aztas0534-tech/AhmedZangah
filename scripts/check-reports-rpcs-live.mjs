import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const loadEnv = (filePath) => {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    for (const line of raw.split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith('#')) continue;
      const i = t.indexOf('=');
      if (i <= 0) continue;
      const k = t.slice(0, i).trim();
      let v = t.slice(i + 1).trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      if (!process.env[k]) process.env[k] = v;
    }
  } catch {
  }
};

loadEnv(path.join(process.cwd(), '.env.local'));
loadEnv(path.join(process.cwd(), '.env.development.local'));
loadEnv(path.join(process.cwd(), '.env.production'));

const url = String(process.env.AZTA_SUPABASE_URL || process.env.VITE_SUPABASE_URL || '').trim();
const key = String(process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.AZTA_SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY || '').trim();
if (!url || !key) {
  throw new Error('Missing Supabase URL/key');
}

const supabase = createClient(url, key);

const runRpc = async (name, args) => {
  try {
    const { data, error } = await supabase.rpc(name, args);
    if (error) {
      return {
        ok: false,
        code: String(error.code || ''),
        message: String(error.message || ''),
        details: String(error.details || ''),
      };
    }
    return {
      ok: true,
      rows: Array.isArray(data) ? data.length : (data ? 1 : 0),
      kind: Array.isArray(data) ? 'array' : typeof data,
    };
  } catch (e) {
    return { ok: false, code: 'EXCEPTION', message: String(e?.message || e) };
  }
};

const today = new Date();
const ymd = today.toISOString().slice(0, 10);
const startTs = `${ymd}T00:00:00Z`;
const endTs = `${ymd}T23:59:59Z`;

const checks = {};
checks.app_schema_healthcheck = await runRpc('app_schema_healthcheck', {});
checks.get_sales_report_summary = await runRpc('get_sales_report_summary', { p_start_date: startTs, p_end_date: endTs, p_zone_id: null, p_invoice_only: false });
checks.get_sales_report_orders = await runRpc('get_sales_report_orders', { p_start_date: startTs, p_end_date: endTs, p_zone_id: null, p_invoice_only: false, p_search: null, p_limit: 50, p_offset: 0 });
checks.get_daily_sales_stats_v2 = await runRpc('get_daily_sales_stats_v2', { p_start_date: startTs, p_end_date: endTs, p_zone_id: null, p_invoice_only: false, p_warehouse_id: null });
checks.get_daily_sales_stats = await runRpc('get_daily_sales_stats', { p_start_date: startTs, p_end_date: endTs, p_zone_id: null, p_invoice_only: false });
checks.get_payment_method_stats = await runRpc('get_payment_method_stats', { p_start_date: startTs, p_end_date: endTs, p_zone_id: null, p_invoice_only: false });
checks.get_product_sales_report_v9 = await runRpc('get_product_sales_report_v9', { p_start_date: startTs, p_end_date: endTs, p_zone_id: null, p_invoice_only: false });
checks.trial_balance_4 = await runRpc('trial_balance', { p_start: ymd, p_end: ymd, p_cost_center_id: null, p_journal_id: null });
checks.trial_balance_3 = await runRpc('trial_balance', { p_start: ymd, p_end: ymd, p_cost_center_id: null });
checks.trial_balance_2 = await runRpc('trial_balance', { p_start: ymd, p_end: ymd });
checks.income_statement = await runRpc('income_statement', { p_start: ymd, p_end: ymd, p_cost_center_id: null, p_journal_id: null });
checks.balance_sheet = await runRpc('balance_sheet', { p_as_of: ymd, p_cost_center_id: null, p_journal_id: null });
checks.currency_balances = await runRpc('currency_balances', { p_start: ymd, p_end: ymd, p_cost_center_id: null, p_journal_id: null });

const fxDiag = { ok: true, delivered_non_base_orders: 0, mismatched_base_total: 0, sample: [] };
try {
  const { data, error } = await supabase
    .from('orders')
    .select('id,status,currency,fx_rate,base_total,data,created_at')
    .eq('status', 'delivered')
    .gte('created_at', new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString())
    .order('created_at', { ascending: false })
    .limit(200);
  if (error) {
    fxDiag.ok = false;
    fxDiag.error = { code: String(error.code || ''), message: String(error.message || '') };
  } else {
    const rows = Array.isArray(data) ? data : [];
    for (const r of rows) {
      const c = String(r?.currency || '').toUpperCase();
      if (!c || c === 'SAR') continue;
      fxDiag.delivered_non_base_orders += 1;
      const total = Number(r?.data?.total ?? 0) || 0;
      const fx = Number(r?.fx_rate ?? 1) || 1;
      const base = Number(r?.base_total ?? 0) || 0;
      const computed = total * fx;
      if (Math.abs(base - computed) > 0.01) {
        fxDiag.mismatched_base_total += 1;
        if (fxDiag.sample.length < 10) {
          fxDiag.sample.push({ id: String(r?.id || ''), currency: c, total, fx_rate: fx, base_total: base, computed_base: computed });
        }
      }
    }
  }
} catch (e) {
  fxDiag.ok = false;
  fxDiag.error = { code: 'EXCEPTION', message: String(e?.message || e) };
}

const report = {
  timestamp: new Date().toISOString(),
  checks,
  fx_diag: fxDiag,
};

fs.writeFileSync(path.join(process.cwd(), 'backups', 'reports_live_check.json'), JSON.stringify(report, null, 2), 'utf8');
console.log('reports_live_check.json');
