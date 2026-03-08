import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch {}
try { envLocal += fs.readFileSync('.env.production', 'utf8'); } catch {}

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
    else if (!supabaseKey && line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function check() {
  // Find a real pending order to see the production state
  const { data: orders, error: orderErr } = await supabase
    .from('orders')
    .select('id, status, data, created_at')
    .limit(5)
    .order('created_at', { ascending: false });

  if (orderErr) {
    console.log("Error fetching orders:", JSON.stringify(orderErr));
  } else {
    console.log(`Found ${orders?.length || 0} orders`);
    if (orders?.length) {
      for (const o of orders) {
        console.log(`  Order ${o.id}: status=${o.status}, has_data=${o.data !== null}, created=${o.created_at}`);
        if (o.data) {
          console.log(`    data keys: ${Object.keys(o.data).join(', ')}`);
        }
      }
    }
  }

  // Check stock_management for data column
  console.log('\n=== stock_management table ===');
  const { data: sm, error: smErr } = await supabase
    .from('stock_management')
    .select('item_id, warehouse_id, data')
    .limit(1);
  console.log("Error:", JSON.stringify(smErr));
  console.log("Rows:", sm?.length);
  if (sm?.length) console.log("Sample:", JSON.stringify(sm[0]).substring(0, 200));

  // Check if there are any columns called 'data' in key tables
  console.log('\n=== Checking data column existence via SELECT ===');
  const tables = ['orders', 'inventory_movements', 'batches', 'stock_management', 'payments'];
  for (const table of tables) {
    const { data: d, error: e } = await supabase
      .from(table)
      .select('data')
      .limit(1);
    console.log(`  ${table}.data: ${e ? 'ERROR: ' + e.message : 'OK (' + (d?.length || 0) + ' rows)'}`);
  }

  // Try tables that SHOULDN'T have data column  
  console.log('\n=== Checking tables that should NOT have data column ===');
  const noDataTables = ['order_item_cogs', 'order_events', 'journal_entries', 'batch_balances'];
  for (const table of noDataTables) {
    const { data: d, error: e } = await supabase
      .from(table)
      .select('data')
      .limit(1);
    console.log(`  ${table}.data: ${e ? 'ERROR: ' + e.code + ' ' + e.message : 'OK (' + (d?.length || 0) + ' rows)'}`);
  }

  // Get the actual confirm_order_delivery function source
  console.log('\n=== Checking function overloads ===');
  // List all confirm_order_delivery* functions to see which overloads exist
  const { data: funcs, error: funcErr } = await supabase
    .from('pg_catalog.pg_proc')  // won't work via PostgREST
    .select('proname')
    .like('proname', 'confirm_order_delivery%');
  if (funcErr) {
    console.log("Cannot query pg_proc via PostgREST (expected):", funcErr.code);
  }

  // Test calling confirm_order_delivery directly with 4 args 
  console.log('\n=== Testing confirm_order_delivery with dummy order ===');
  const { data: cd, error: cdErr } = await supabase.rpc('confirm_order_delivery', {
    p_order_id: '00000000-0000-0000-0000-000000000000',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000000'
  });
  console.log("Result:", JSON.stringify(cdErr));

  // Test calling confirm_order_delivery_rpc with dummy order
  console.log('\n=== Testing confirm_order_delivery_rpc with dummy order ===');
  const { data: cr, error: crErr } = await supabase.rpc('confirm_order_delivery_rpc', {
    p_order_id: '00000000-0000-0000-0000-000000000000',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000000'
  });
  console.log("Result:", JSON.stringify(crErr));
}

check();
