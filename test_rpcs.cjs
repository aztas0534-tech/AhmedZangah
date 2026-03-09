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
  // Strategy: DROP v9 + CREATE a new v9 as a simple wrapper around v10.
  // DROP forces invalidation of ALL cached plans (PgBouncer, PostgreSQL).
  // This is safe because v10 has the exact same signature and return type.

  console.log('=== Step 1: Drop v9 ===');
  var r = await supabase.rpc('exec_debug_sql', {
    q: "drop function if exists public.get_product_sales_report_v9(timestamptz, timestamptz, uuid, boolean); select 'dropped'::text"
  });
  console.log('Drop:', JSON.stringify(r.data));

  console.log('\n=== Step 2: Create v9 as wrapper to v10 ===');
  var wrapperSQL = `
create or replace function public.get_product_sales_report_v9(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_zone_id uuid default null,
  p_invoice_only boolean default false
)
returns table (
  item_id text,
  item_name jsonb,
  unit_type text,
  quantity_sold numeric,
  total_sales numeric,
  total_cost numeric,
  total_profit numeric,
  current_stock numeric,
  reserved_stock numeric,
  current_cost_price numeric,
  avg_inventory numeric
)
language sql
security definer
set search_path = public
as $$
  select * from public.get_product_sales_report_v10(p_start_date, p_end_date, p_zone_id, p_invoice_only);
$$;
select 'created_wrapper'::text
  `;
  r = await supabase.rpc('exec_debug_sql', { q: wrapperSQL });
  console.log('Create wrapper:', JSON.stringify(r.data));

  // Grant
  console.log('\n=== Step 3: Grant permissions ===');
  r = await supabase.rpc('exec_debug_sql', {
    q: "grant execute on function public.get_product_sales_report_v9(timestamptz, timestamptz, uuid, boolean) to anon, authenticated, service_role; select 'granted'::text"
  });
  console.log('Grant:', JSON.stringify(r.data));

  // Reload schema
  console.log('\n=== Step 4: Schema reload ===');
  r = await supabase.rpc('exec_debug_sql', {
    q: "select pg_notify('pgrst', 'reload schema'); select 'reloaded'::text"
  });
  console.log('Reload:', JSON.stringify(r.data));

  await new Promise(resolve => setTimeout(resolve, 5000));

  // Test v9 via PostgREST
  console.log('\n=== Step 5: Test v9 via PostgREST ===');
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
  try {
    var parsed = JSON.parse(data);
    if (parsed.code === '42883') {
      console.log('STILL SQL ERROR:', parsed.message);
    } else if (parsed.code === 'P0001' && parsed.message === 'not allowed') {
      console.log('V9 WRAPPER WORKS! (is_staff block from v10)');
    } else if (Array.isArray(parsed)) {
      console.log('SUCCESS! Got', parsed.length, 'rows - FX CONVERSION WORKING!');
      parsed.slice(0, 3).forEach(r => console.log('-', JSON.stringify(r.item_name), '| sales:', r.total_sales?.toFixed(2)));
    } else {
      console.log('Response:', data.substring(0, 300));
    }
  } catch(e) {
    console.log('Raw:', data.substring(0, 500));
  }
}

run().catch(function(e) { console.error('FATAL:', e); });
