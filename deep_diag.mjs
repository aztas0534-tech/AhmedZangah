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
  // 1. Check if orders table has data column by inserting a temp row  
  console.log("=== Test 1: Can we SELECT data from orders? ===");
  const res1 = await supabase.from('orders').select('id, data').limit(1);
  console.log("Error:", JSON.stringify(res1.error));
  console.log("Rows:", res1.data?.length);
  
  // 2. Directly try to update an order with data
  console.log("\n=== Test 2: Can we UPDATE orders SET data? ===");
  const res2 = await supabase.from('orders').update({ data: { test: true }, updated_at: new Date().toISOString() }).eq('id', '00000000-0000-0000-0000-000000000000');
  console.log("Error:", JSON.stringify(res2.error));

  // 3. Get column info with SQL 
  console.log("\n=== Test 3: Getting column info via RPC ===");
  // Try a simple existence check by inserting into a temp order 
  const res3 = await supabase.from('orders').insert({
    id: 'aaaaaaaa-0000-0000-0000-000000000001',
    status: 'test_diag',
    data: { diag: true }
  });
  console.log("Insert error:", JSON.stringify(res3.error));
  
  // Clean up
  if (!res3.error) {
    await supabase.from('orders').delete().eq('id', 'aaaaaaaa-0000-0000-0000-000000000001');
    console.log("Test row cleaned up");
  }
  
  // 4. Check ALL columns of orders table
  console.log("\n=== Test 4: Checking all columns via a select * ===");
  const res4 = await supabase.from('orders').select('*').limit(1);
  if (res4.data && res4.data.length > 0) {
    console.log("Columns in result:", Object.keys(res4.data[0]).sort().join(', '));
    console.log("Has 'data' column:", 'data' in res4.data[0]);
  } else {
    console.log("No rows to inspect columns, error:", JSON.stringify(res4.error));
  }
}

check();
