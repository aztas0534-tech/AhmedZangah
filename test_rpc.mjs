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

console.log('Using URL:', supabaseUrl);
console.log('Is Service Role Key:', supabaseKey.length > 100);

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
  const v_o = '11111111-1111-1111-1111-111111111111';
  const v_b = '22222222-2222-2222-2222-222222222222';
  
  const args = {
    p_order_id: v_o,
    p_items: [],
    p_updated_data: { status: 'delivered', data: { test: 1 } },
    p_warehouse_id: v_b
  };
  console.log('Testing direct4 arguments mapping...');
  const res1 = await supabase.rpc('confirm_order_delivery_with_credit', args);
  console.log('Result 1:', JSON.stringify(res1));

  const payloadArgs = {
    p_payload: {
      p_order_id: v_o,
      p_items: [],
      p_updated_data: { status: 'delivered', data: { test: 1 } },
      p_warehouse_id: v_b
    }
  };
  console.log('Testing wrapper payload mapping...');
  const res2 = await supabase.rpc('confirm_order_delivery_with_credit', payloadArgs);
  console.log('Result 2:', JSON.stringify(res2));
}

run();
