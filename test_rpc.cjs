const { createClient } = require('@supabase/supabase-js');
const fs = require('fs');

function getEnv(path) {
  let txt = '';
  try { txt = fs.readFileSync(path, 'utf8'); } catch {}
  const res = {};
  txt.split('\n').forEach(l => {
    let parts = l.split('=');
    if (parts.length > 1) {
      let key = parts[0].trim();
      let val = parts.slice(1).join('=').trim();
      if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
      if (val.startsWith("'") && val.endsWith("'")) val = val.slice(1, -1);
      res[key] = val;
    }
  });
  return res;
}

const e1 = getEnv('.env');
const e2 = getEnv('.env.local');
const e3 = getEnv('.env.production');

const url = e3.NEXT_PUBLIC_SUPABASE_URL || e2.NEXT_PUBLIC_SUPABASE_URL || e1.NEXT_PUBLIC_SUPABASE_URL || '';
const key = e3.SUPABASE_SERVICE_ROLE_KEY || e2.SUPABASE_SERVICE_ROLE_KEY || e1.SUPABASE_SERVICE_ROLE_KEY || 
            e3.NEXT_PUBLIC_SUPABASE_ANON_KEY || e2.NEXT_PUBLIC_SUPABASE_ANON_KEY || e1.NEXT_PUBLIC_SUPABASE_ANON_KEY || '';

const supabase = createClient(url, key);

async function run() {
  const v_o = '11111111-1111-1111-1111-111111111111';
  const v_b = '22222222-2222-2222-2222-222222222222';
  
  const args = {
    p_order_id: v_o,
    p_items: [],
    p_updated_data: { status: 'delivered', data: { test: 1 } },
    p_warehouse_id: v_b
  };
  console.log('Testing legacy signature arguments mapping...');
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
  console.log('Testing new JSON payload mapping...');
  const res2 = await supabase.rpc('confirm_order_delivery_with_credit', payloadArgs);
  console.log('Result 2:', JSON.stringify(res2));
}

run();
