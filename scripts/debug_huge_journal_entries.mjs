
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function debugHugeEntries() {
    console.log('--- Searching for Huge Journal Entries (> 1,000,000) ---');

    // Find JEs with large debit amounts
    const { data: hugeLines, error } = await supabase
        .from('journal_lines')
        .select(`
        id, 
        debit, 
        credit, 
        journal_entry_id,
        journal_entry:journal_entries (
            id,
            source_table,
            source_id,
            source_event,
            memo,
            created_at
        )
    `)
        .gt('debit', 1000000)
        .limit(5);

    if (error) {
        console.error('Error finding huge entries:', error);
        return;
    }

    if (!hugeLines || hugeLines.length === 0) {
        console.log('No huge entries found > 1,000,000 SAR.');
        return;
    }

    console.log(`Found ${hugeLines.length} huge entries.`);

    for (const line of hugeLines) {
        const je = line.journal_entry;
        console.log(`\nEntry ID: ${je.id}`);
        console.log(`Amount: ${line.debit} SAR`);
        console.log(`Source: ${je.source_table} ID: ${je.source_id} Event: ${je.source_event}`);
        console.log(`Memo: ${je.memo}`);

        // If source is 'purchase_receipts', investigate the receipt & PO
        if (je.source_table === 'purchase_receipts' && je.source_id) {
            await investigateReceipt(je.source_id);
        } else if (je.source_table === 'import_shipments' && je.source_id) {
            await investigateShipment(je.source_id); // Implement if needed
        }
    }
}

async function investigateReceipt(receiptId) {
    console.log(`  -> Investigating Receipt ${receiptId}...`);

    const { data: r, error } = await supabase
        .from('purchase_receipts')
        .select(`
            id, 
            warehouse_id,
            purchase_order_id,
            purchase_order:purchase_orders (
                id,
                currency,
                fx_rate,
                exchange_rate,
                total_amount
            ),
            items:purchase_receipt_items (
                id,
                item_id,
                quantity,
                unit_cost,
                total_cost,
                transport_cost,
                supply_tax_cost
            )
        `)
        .eq('id', receiptId)
        .single();

    if (error || !r) {
        console.error('    Error fetching receipt:', error);
        return;
    }

    const po = r.purchase_order;
    console.log(`    Linked PO: ${po.id}`);
    console.log(`    PO Currency: ${po.currency}`);
    console.log(`    PO FX Rate (fx_rate): ${po.fx_rate}`);
    console.log(`    PO Exchange Rate (exchange_rate): ${po.exchange_rate}`);

    if (r.items && r.items.length > 0) {
        console.log('    Receipt Items:');
        r.items.forEach(item => {
            console.log(`      Item ${item.item_id}: Qty=${item.quantity}, UnitCost=${item.unit_cost}, Total=${item.total_cost}`);
            console.log(`        Transport=${item.transport_cost}, Tax=${item.supply_tax_cost}`);
        });
    }
}

async function investigateShipment(shipmentId) {
    console.log(`  -> Investigating Shipment ${shipmentId}...`);
    // Similar logic for Shipment if needed
}

debugHugeEntries();
