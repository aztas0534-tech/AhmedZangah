
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function inspectTransaction() {
    const REF = '444524';
    console.log(`--- Inspecting Transaction #${REF} ---`);

    // 1. Search PO
    const { data: po, error: poError } = await supabase
        .from('purchase_orders')
        .select('*')
        .ilike('reference_number', `%${REF}%`); // partial match

    if (po && po.length > 0) {
        console.log('Found Purchase Order(s):');
        console.table(po.map(p => ({ id: p.id, ref: p.reference_number, currency: p.currency, fx: p.fx_rate })));

        // Check Receipts for this PO
        for (const p of po) {
            await checkReceipts(p.id);
        }
    } else {
        console.log('No PO found with this reference.');
    }

    // 2. Search Journal Entries directly
    const { data: je, error: jeError } = await supabase
        .from('journal_entries')
        .select('id, memo, source_table, source_id')
        .ilike('memo', `%${REF}%`);

    if (je && je.length > 0) {
        console.log('Found Journal Entries by Memo:');
        console.table(je);
        for (const j of je) {
            if (j.source_table === 'purchase_receipts') {
                await checkReceiptsByReceiptId(j.source_id);
            } else if (j.source_table === 'inventory_movements') {
                // movements usually link to receipt
                console.log(`Source is movement: ${j.source_id}`);
            }
        }
    } else {
        console.log('No Journals found with this memo.');
    }

}

async function checkReceipts(poId) {
    console.log(`Checking Receipts for PO ${poId}...`);
    const { data: receipts } = await supabase
        .from('purchase_receipts')
        .select(`
            id, 
            purchase_order_id,
            total_amount,
            items:purchase_receipt_items(
                id, item_id, quantity, unit_cost, total_cost, transport_cost, supply_tax_cost
            )
        `)
        .eq('purchase_order_id', poId);

    if (receipts) {
        receipts.forEach(r => {
            console.log(`Receipt ${r.id}:`);
            console.table(r.items);
        });
    }
}

async function checkReceiptsByReceiptId(id) {
    // reusing logic
    const { data: receipts } = await supabase
        .from('purchase_receipts')
        .select(`
            id, 
            purchase_order_id,
            items:purchase_receipt_items(
                id, item_id, quantity, unit_cost, total_cost, transport_cost, supply_tax_cost
            )
        `)
        .eq('id', id);

    if (receipts) {
        receipts.forEach(r => {
            console.log(`Receipt ${r.id} (from JE):`);
            if (r.items) console.table(r.items);
            // Also fetch PO to see currency
            checkPO(r.purchase_order_id);
        });
    }
}

async function checkPO(id) {
    const { data: po } = await supabase.from('purchase_orders').select('*').eq('id', id).single();
    if (po) {
        console.log(`PO Details for Receipt: Currency=${po.currency}, FX=${po.fx_rate}`);
    }
}

inspectTransaction();
