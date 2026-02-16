
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials from debug_pricing.mjs
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz'; // Service Role Key

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function inspectReceiptData() {
    console.log('--- Inspecting Initial Purchase Receipt Data ---');

    // Find a Purchase Order in a foreign currency (not SAR)
    const { data: po, error: poError } = await supabase
        .from('purchase_orders')
        .select('id, currency, exchange_rate')
        .neq('currency', 'SAR')
        .limit(1)
        .single();

    if (poError || !po) {
        console.log('No Foreign Currency PO found to test with.');
        // Fallback: just get any PO
        return;
    }

    console.log(`Found Foreign PO: ${po.id} (${po.currency} @ ${po.exchange_rate})`);

    // Get Receipts for this PO
    const { data: receipts, error: rError } = await supabase
        .from('purchase_receipts')
        .select(`
        id, 
        transport_cost, 
        supply_tax_cost, 
        items:purchase_receipt_items (
            id, 
            transport_cost, 
            supply_tax_cost, 
            quantity,
            unit_cost
        )
    `)
        .eq('purchase_order_id', po.id)
        .limit(1);

    if (rError) {
        console.error('Error fetching receipts:', rError);
        return;
    }

    if (receipts && receipts.length > 0) {
        console.log('Receipt Data (Linked to Foreign PO):');
        console.log(JSON.stringify(receipts[0], null, 2));
    } else {
        console.log('No receipts found for this PO.');
    }
}

inspectReceiptData();
