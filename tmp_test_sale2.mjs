import { createClient } from '@supabase/supabase-js';
import * as fs from 'fs';

const envVars = fs.readFileSync('.env.production', 'utf8');
const urlMatch = envVars.match(/VITE_SUPABASE_URL=(.*)/);
const keyMatch = envVars.match(/VITE_SUPABASE_ANON_KEY=(.*)/);
const supabaseUrl = urlMatch ? urlMatch[1].trim() : '';
const supabaseKey = keyMatch ? keyMatch[1].trim() : '';

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
  console.log('Logging in...');
  const { data: authData, error: authErr } = await supabase.auth.signInWithPassword({
    email: 'owner@azta.com',
    password: 'AhmedZ#123456',
  });
  if (authErr) throw authErr;

  const orderId = crypto.randomUUID();
  console.log('Test order ID:', orderId);

  // Step 1: Insert order
  console.log('Step 1: Inserting order...');
  const { error: insertErr } = await supabase.from('orders').insert({
    id: orderId,
    customer_auth_user_id: authData.user.id,
    warehouse_id: '7628598d-3c02-4a55-b7db-76df1c421175',
    currency: 'YER',
    subtotal: 100,
    total: 100,
    payment_method: 'cash',
    status: 'pending',
    data: {
      orderSource: 'in_store',
    }
  });

  if (insertErr) {
    console.error('Insert failed:', insertErr);
    return;
  }
  console.log('Insert succeeded!');

  // Step 2: Verify order exists
  console.log('Step 2: Verifying order exists...');
  const { data: order, error: fetchErr } = await supabase.from('orders').select('id, status').eq('id', orderId).single();
  if (fetchErr) {
    console.error('Fetch failed:', fetchErr);
    return;
  }
  console.log('Order found:', order);

  // Step 3: Call confirm_order_delivery_with_credit with the 4-param signature
  console.log('Step 3: Calling confirm_order_delivery_with_credit...');
  const t0 = Date.now();
  const { data: rpcData, error: rpcError } = await supabase.rpc('confirm_order_delivery_with_credit', {
    p_order_id: orderId,
    p_items: [{
      itemId: '66530237-b448-4bd2-a53e-110b599b799b',
      quantity: 1,
      uomQtyInBase: 1,
      warehouseId: '7628598d-3c02-4a55-b7db-76df1c421175'
    }],
    p_updated_data: {
      orderSource: 'in_store',
      status: 'delivered',
      total: 100,
      subtotal: 100,
      paymentMethod: 'cash',
      paidAt: new Date().toISOString(),
      invoiceSnapshot: {
        issuedAt: new Date().toISOString(),
        invoiceNumber: 'TEST-' + Date.now(),
        currency: 'YER',
        fxRate: 1,
        baseCurrency: 'YER',
        items: [{
          id: '66530237-b448-4bd2-a53e-110b599b799b',
          quantity: 1,
          price: 100,
        }],
        subtotal: 100,
        total: 100,
        paymentMethod: 'cash',
      }
    },
    p_warehouse_id: '7628598d-3c02-4a55-b7db-76df1c421175'
  });
  const t1 = Date.now();

  if (rpcError) {
    console.error(`RPC Error (${t1 - t0}ms):`, rpcError);
  } else {
    console.log(`RPC Success (${t1 - t0}ms):`, rpcData);
  }
}

run().catch(console.error);
