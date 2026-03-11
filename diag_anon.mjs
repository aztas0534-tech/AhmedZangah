import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch {}
try { envLocal += fs.readFileSync('.env.production', 'utf8'); } catch {}

let supabaseUrl = '';
let supabaseAnonKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseAnonKey = line.split('=')[1].trim();
}

// Use anon key to simulate frontend behavior
const supabase = createClient(supabaseUrl, supabaseAnonKey);

async function check() {
  // Test with anon key (like frontend does before auth)
  const res = await supabase.rpc('confirm_order_delivery_rpc', {
    p_order_id: '00000000-0000-0000-0000-000000000000',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000000',
  });
  console.log("confirm_order_delivery_rpc with anon:", JSON.stringify(res.error));
  
  // Check if the function source was actually updated
  // We can do this by looking at the error message - if it says "permission denied"
  // that's good (function exists), if it says "column data does not exist" that's the old version
  
  // Try calling the base function directly to see if it works
  const res2 = await supabase.rpc('confirm_order_delivery', {
    p_order_id: '00000000-0000-0000-0000-000000000000',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000000',
  });
  console.log("confirm_order_delivery with anon:", JSON.stringify(res2.error));
}

check();
