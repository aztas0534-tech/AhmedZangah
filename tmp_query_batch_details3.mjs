import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
let envProd = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch { }
try { envProd = fs.readFileSync('.env.production', 'utf8'); } catch { }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envProd.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
}
for (const line of envLocal.split('\n')) {
    if (!supabaseUrl && line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
}

console.log("Using URL:", supabaseUrl);
console.log("Has Key:", !!supabaseKey);

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const receiptId = '218f4547-e896-4f2f-97f1-839eb58cb179';
    const itemId = '33b3c8a8-d5ec-48cb-bf5d-a58ae003c98e';

    const { data: receipt, error: recErr } = await supabase
        .from('purchase_receipts')
        .select('*')
        .eq('id', receiptId)
        .single();

    if (recErr || !receipt) {
        console.error("Receipt error:", recErr);
        return;
    }

    const orderId = receipt.purchase_order_id;
    const { data: order } = await supabase
        .from('purchase_orders')
        .select('*')
        .eq('id', orderId)
        .single();

    const { data: receiptItems } = await supabase
        .from('purchase_receipt_items')
        .select('*')
        .eq('receipt_id', receiptId)
        .eq('item_id', itemId);

    const { data: orderItems } = await supabase
        .from('purchase_items')
        .select('*')
        .eq('purchase_order_id', orderId)
        .eq('item_id', itemId);

    console.log("== PO ==");
    console.log(order);
    console.log("== PO Items ==");
    console.log(orderItems);
    console.log("== Receipt ==");
    console.log(receipt);
    console.log("== Receipt Items ==");
    console.log(receiptItems);
}

run();
