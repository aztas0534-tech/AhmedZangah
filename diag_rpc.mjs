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
  // Test 1: Does confirm_order_delivery_rpc exist?
  const res = await supabase.rpc('confirm_order_delivery_rpc', {
    p_order_id: '00000000-0000-0000-0000-000000000000',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000000',
  });
  console.log("confirm_order_delivery_rpc error:", JSON.stringify(res.error));
  
  // Test 2: Does confirm_order_delivery exist with 4 args?
  const res2 = await supabase.rpc('confirm_order_delivery', {
    p_order_id: '00000000-0000-0000-0000-000000000000',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000000',
  });
  console.log("confirm_order_delivery error:", JSON.stringify(res2.error));

  // Test 3: Check if orders table actually has data column  
  const res3 = await supabase.from('orders').select('id, data, status').limit(1);
  console.log("orders select id,data,status:", JSON.stringify(res3.error), "rows:", res3.data?.length);
  if (res3?.data?.length) console.log("sample:", JSON.stringify(res3.data[0]).substring(0,200));
  
  // Test 4: Try a simple UPDATE on orders data
  const res4 = await supabase.from('orders').update({ data: {} }).eq('id', '00000000-0000-0000-0000-000000000000');
  console.log("orders update data:", JSON.stringify(res4.error));
}

check();
