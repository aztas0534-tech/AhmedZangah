import * as fs from 'fs';
import { createClient } from '@supabase/supabase-js';

const envFile = fs.readFileSync('c:\\nasrflash\\AhmedZ\\.env.local', 'utf-8');
const env: Record<string, string> = {};
envFile.split(/\r?\n/).forEach(line => {
  const match = line.match(/^([^=]+)=(.*)$/);
  if (match) env[match[1].trim()] = match[2].trim();
});

const url = env['VITE_SUPABASE_URL'];
const key = env['VITE_SUPABASE_SERVICE_ROLE_KEY'] || env['VITE_SUPABASE_ANON_KEY'];
const supabase = createClient(url, key);

/**
 * Push a SQL migration file to production via exec_debug_sql.
 * Strips BEGIN/COMMIT transactions and wraps in DO $$ block if needed.
 */
async function pushMigration(filePath: string, label: string) {
  console.log(`\n📦 Pushing: ${label}`);
  console.log(`   File: ${filePath}`);
  
  let sql = fs.readFileSync(filePath, 'utf-8');
  // Strip transaction wrappers that won't work inside exec_debug_sql
  sql = sql.replace(/^begin;/gim, '').replace(/^commit;/gim, '');
  // Strip pg_sleep calls
  sql = sql.replace(/select pg_sleep\([^)]+\);/gi, '');
  
  const result = await supabase.rpc('exec_debug_sql', { q: sql });
  if (result.error) {
    console.error(`   ❌ Error: ${JSON.stringify(result.error)}`);
    return false;
  }
  console.log(`   ✅ OK`);
  return true;
}

async function run() {
  console.log('🔧 Report RPCs Production Push Script');
  console.log('=====================================');
  console.log(`Target: ${url}`);
  console.log(`Time: ${new Date().toISOString()}\n`);
  
  const migrations: Array<{ path: string; label: string }> = [
    {
      path: 'c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260225203000_fix_sales_report_summary_tax_refunds.sql',
      label: '1. Sales Report Summary (FX-aware, latest version)'
    },
    {
      path: 'c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260301051500_get_sales_by_currency.sql',
      label: '2. Sales by Currency RPC'
    },
    {
      path: 'c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260309230000_product_report_v9_fx_rate.sql',
      label: '3. Product Sales Report V9 (FX-aware fix)'
    },
    {
      path: 'c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260115256000_product_sales_report_unified.sql',
      label: '4. Product Sales Report Unified wrapper'
    },
  ];
  
  let success = 0;
  let failed = 0;
  
  for (const m of migrations) {
    const ok = await pushMigration(m.path, m.label);
    if (ok) success++;
    else failed++;
  }
  
  // Reload schema cache
  console.log('\n🔄 Reloading PostgREST schema cache...');
  const reload = await supabase.rpc('exec_debug_sql', { q: "notify pgrst, 'reload schema';" });
  if (reload.error) {
    console.error('   ⚠️ Schema reload notification failed:', reload.error);
  } else {
    console.log('   ✅ Schema cache reloaded');
  }
  
  console.log(`\n📋 Summary: ${success} succeeded, ${failed} failed`);
}

run();
