import { createClient } from '@supabase/supabase-js';
import * as dotenv from 'dotenv';
dotenv.config({ path: '.env.local' });

const supabaseUrl = process.env.VITE_SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseKey = process.env.VITE_SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseKey) {
    console.error("Missing Supabase credentials in .env.local");
    process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function testPayment() {
    const orderId = 'a1f81d1e-26ec-4bb0-8041-35baceb032ce'; // an example order ID, we need one from the DB

    const { data: order, error: orderErr } = await supabase
        .from('orders')
        .select('*')
        .eq('status', 'delivered')
        .limit(1)
        .single();

    if (orderErr || !order) {
        console.error("Could not fetch a delivered order for testing", orderErr);
        return;
    }

    console.log("Testing on order:", order.id);

    console.log("1. Calling record_order_payment_v2...");
    const { error: rpcErr } = await supabase.rpc('record_order_payment_v2', {
        p_order_id: order.id,
        p_amount: 100,
        p_method: 'cash',
        p_occurred_at: new Date().toISOString(),
        p_currency: 'YER',
        p_idempotency_key: `test-${Date.now()}`
    });

    if (rpcErr) {
        console.error("RPC Error:", rpcErr);
    } else {
        console.log("RPC Success!");
    }

    console.log("2. Updating order data...");
    const updatedData = { ...order.data, test: 'value' };
    const { error: updErr } = await supabase
        .from('orders')
        .update({ data: updatedData })
        .eq('id', order.id);

    if (updErr) {
        console.error("Update Error:", updErr);
    } else {
        console.log("Update Success!");
    }
}

testPayment();
