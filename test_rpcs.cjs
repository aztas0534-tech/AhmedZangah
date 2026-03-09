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

async function run() {
  // The issue may be that PostgREST cached the prep statement with the OLD function body.
  // Supabase PostgREST runs in a connection pool (PgBouncer). Each connection may have 
  // a cached prepared statement with the old function body.
  //
  // The fix: re-create the function with CREATE OR REPLACE again after the schema reload.
  // This forces PostgreSQL to invalidate cached plans.
  
  console.log('=== Force schema reload + function re-create ===');

  // First, read the fixed SQL
  const migrationSQL = fs.readFileSync(
    'c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260309230000_product_report_v9_fx_rate.sql',
    'utf-8'
  );
  const endOfFunction = migrationSQL.indexOf('$$;');
  const createFunctionSQL = migrationSQL.substring(0, endOfFunction + 3);

  // Step 1: Schema reload
  var r = await supabase.rpc('exec_debug_sql', {
    q: "select pg_notify('pgrst', 'reload schema'); select pg_notify('pgrst', 'reload config'); select 'step1_done'::text"
  });
  console.log('Step 1 (schema reload):', JSON.stringify(r.data));

  // Step 2: Wait
  await new Promise(resolve => setTimeout(resolve, 3000));

  // Step 3: Re-deploy the function (forces plan cache invalidation)
  r = await supabase.rpc('exec_debug_sql', {
    q: createFunctionSQL + "; select 'step3_done'::text"
  });
  console.log('Step 3 (re-deploy):', JSON.stringify(r.data));

  // Step 4: Re-grant
  r = await supabase.rpc('exec_debug_sql', {
    q: "grant execute on function public.get_product_sales_report_v9(timestamptz, timestamptz, uuid, boolean) to anon, authenticated, service_role; select 'step4_done'::text"
  });
  console.log('Step 4 (grant):', JSON.stringify(r.data));

  // Step 5: Another schema reload
  r = await supabase.rpc('exec_debug_sql', {
    q: "select pg_notify('pgrst', 'reload schema'); select 'step5_done'::text"
  });
  console.log('Step 5 (reload):', JSON.stringify(r.data));

  // Step 6: Wait longer
  await new Promise(resolve => setTimeout(resolve, 5000));

  // Step 7: Test via PostgREST with service key
  console.log('\n=== PostgREST test ===');
  var resp = await fetch(url + '/rest/v1/rpc/get_product_sales_report_v9', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'apikey': serviceKey,
      'Authorization': 'Bearer ' + serviceKey,
    },
    body: JSON.stringify({
      p_start_date: '2026-03-09T00:00:00+03:00',
      p_end_date: '2026-03-09T23:59:59+03:00',
      p_zone_id: null,
      p_invoice_only: false,
    }),
  });
  console.log('Status:', resp.status);
  var data = await resp.text();
  // Parse to see if it's the max(jsonb) error or the is_staff error
  try {
    var parsed = JSON.parse(data);
    if (parsed.code === '42883') {
      console.log('STILL max(jsonb) ERROR:', parsed.message);
    } else if (parsed.code === 'P0001') {
      console.log('is_staff() block (EXPECTED for service key):', parsed.message);
      console.log('FIX IS WORKING - the max(jsonb) issue is resolved!');
    } else if (Array.isArray(parsed)) {
      console.log('SUCCESS! Got', parsed.length, 'rows');
      console.log('First 2:', parsed.slice(0, 2).map(r => r.item_name + ': ' + r.total_sales));
    } else {
      console.log('Unknown response:', data.substring(0, 300));
    }
  } catch(e) {
    console.log('Raw:', data.substring(0, 500));
  }
}

run().catch(function(e) { console.error('FATAL:', e); });
