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

async function deploySql(label, sqlPath) {
  console.log(`\n=== Deploying: ${label} ===`);
  const sql = fs.readFileSync(sqlPath, 'utf-8');
  
  // Split by semicolons but keep CREATE OR REPLACE FUNCTION blocks together
  // Strategy: run the entire file as one exec_debug_sql call
  const r = await supabase.rpc('exec_debug_sql', { q: sql });
  if (r.error) {
    console.log(`ERROR deploying ${label}:`, JSON.stringify(r.error));
    // Try splitting into individual statements
    console.log('Trying statement-by-statement...');
    const statements = splitStatements(sql);
    for (let i = 0; i < statements.length; i++) {
      const stmt = statements[i].trim();
      if (!stmt) continue;
      console.log(`  Statement ${i + 1}/${statements.length}: ${stmt.substring(0, 60).replace(/\n/g, ' ')}...`);
      const r2 = await supabase.rpc('exec_debug_sql', { q: stmt });
      if (r2.error) {
        console.log(`  ERROR:`, r2.error.message || JSON.stringify(r2.error));
      } else {
        console.log(`  OK`);
      }
    }
  } else {
    console.log(`SUCCESS: ${label} deployed.`, JSON.stringify(r.data));
  }
}

function splitStatements(sql) {
  // Split SQL respecting $$ blocks
  const results = [];
  let current = '';
  let inDollar = false;
  const lines = sql.split('\n');
  
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('--') && !inDollar) {
      // Skip pure comments outside functions
      if (!current.trim()) continue;
    }
    
    current += line + '\n';
    
    // Track $$ blocks
    const dollarCount = (line.match(/\$\$/g) || []).length;
    if (dollarCount % 2 === 1) {
      inDollar = !inDollar;
    }
    
    // If not inside a $$ block and line ends with ; then split
    if (!inDollar && trimmed.endsWith(';')) {
      if (current.trim()) {
        results.push(current.trim());
      }
      current = '';
    }
  }
  
  if (current.trim()) {
    results.push(current.trim());
  }
  
  return results;
}

async function testRpc(name, args) {
  console.log(`\n=== Testing: ${name} ===`);
  const r = await supabase.rpc(name, args);
  if (r.error) {
    console.log(`ERROR:`, r.error.message || JSON.stringify(r.error));
    return false;
  }
  console.log(`SUCCESS! Response type:`, typeof r.data);
  if (typeof r.data === 'object' && r.data !== null) {
    const keys = Object.keys(r.data);
    console.log(`Keys:`, keys.join(', '));
    for (const k of keys) {
      const v = r.data[k];
      if (typeof v === 'number') {
        console.log(`  ${k}: ${v}`);
      } else if (Array.isArray(v)) {
        console.log(`  ${k}: [${v.length} items]`);
      } else if (typeof v === 'object' && v !== null) {
        console.log(`  ${k}: {${Object.keys(v).length} keys}`);
      }
    }
  }
  return true;
}

async function run() {
  const now = new Date();
  const startOfDay = new Date(now); startOfDay.setHours(0, 0, 0, 0);
  const endOfDay = new Date(now); endOfDay.setHours(23, 59, 59, 999);
  
  // Deploy shift reconciliation (includes column additions, functions, triggers)
  await deploySql(
    'Cashier Sub-Accounts + Shift Reconciliation',
    'supabase/migrations/20260309033000_cashier_sub_accounts_approval_reconciliation.sql'
  );
  
  // Deploy accountant dashboard summary
  await deploySql(
    'Accountant Dashboard Summary',
    'supabase/migrations/20260309040000_accountant_dashboard_rpc.sql'
  );
  
  // Reload schema
  console.log('\n=== Schema reload ===');
  const rr = await supabase.rpc('exec_debug_sql', {
    q: "select pg_notify('pgrst', 'reload schema'); select 'reloaded'::text"
  });
  console.log('Reload:', JSON.stringify(rr.data));
  
  // Wait for schema cache
  await new Promise(resolve => setTimeout(resolve, 5000));
  
  // Test both RPCs
  await testRpc('get_shift_reconciliation_summary', {
    p_start_date: startOfDay.toISOString(),
    p_end_date: endOfDay.toISOString()
  });
  
  await testRpc('get_accountant_dashboard_summary', {
    p_start_date: startOfDay.toISOString(),
    p_end_date: endOfDay.toISOString()
  });
  
  console.log('\n=== Done ===');
}

run().catch(function(e) { console.error('FATAL:', e); });
