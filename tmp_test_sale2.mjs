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

  console.log('Finding a valid item batch for sale...');
  const { data: batches } = await supabase
    .from('batches')
    .select('id, item_id, warehouse_id, quantity_received, quantity_consumed, quantity_transferred, unit_cost')
    .eq('status', 'active')
    .limit(10);
  
  const validBatch = batches?.find(b => (b.quantity_received - b.quantity_consumed - (b.quantity_transferred||0)) > 2);
  
  if (!validBatch) {
    console.log('Could not find item with enough stock');
    return;
  }
  
  const orderId = crypto.randomUUID();
  const quantity = 1;
  const price = validBatch.unit_cost * 1.5 || 1500;
  const total = price * quantity;

  const payload = {
    orderId,
    items: [
      {
        itemId: validBatch.item_id,
        quantity: quantity,
        uomQtyInBase: 1,
        batchId: validBatch.id,
        warehouseId: validBatch.warehouse_id
      }
    ],
    updatedData: {
      status: 'pending',
      total: total,
      subtotal: total,
      paymentMethod: 'cash',
      paidAt: new Date().toISOString(),
      orderSource: 'in_store'
    },
    warehouseId: validBatch.warehouse_id
  };

  console.log('First creating an order record...');
  const { error: insertErr } = await supabase.from('orders').insert({
    id: orderId,
    customer_auth_user_id: authData.user.id,
    warehouse_id: validBatch.warehouse_id,
    currency: 'YER',
    subtotal: total,
    total: total,
    payment_method: 'cash',
    status: 'pending',
    data: {
      orderSource: 'in_store',
      deliveryZoneId: '00000000-0000-4000-8000-000000000000'
    }
  });

  if (insertErr) {
    console.error('Failed to create order shell', insertErr);
    return;
  }

  console.log('Calling confirm_order_delivery_with_credit...');
  const t0 = Date.now();
  
  const { data, error } = await supabase.rpc('confirm_order_delivery_with_credit', {
    p_payload: payload
  });
  
  const t1 = Date.now();
  if (error) {
    console.error('RPC Error:', error);
  } else {
    console.log(`Success! Transaction completed in ${t1 - t0}ms`);
  }
}

run().catch(console.error);
