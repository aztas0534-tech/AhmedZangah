import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import path from 'path';
import fs from 'fs';

// Load environment variables (optional, since we are hardcoding the key for local debug)
const envLocalPath = path.resolve(process.cwd(), '.env.local');
const envPath = path.resolve(process.cwd(), '.env');

if (fs.existsSync(envLocalPath)) {
    dotenv.config({ path: envLocalPath });
} else if (fs.existsSync(envPath)) {
    dotenv.config({ path: envPath });
}

// Local Supabase Settings
const supabaseUrl = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:54321';
// SERVICE_ROLE_KEY for local development (bypasses RLS)
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxvY2FsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTYyMDAwMDAwMCwiZXhwIjoxOTIwMDAwMDAwfQ.vUYFAkKRn36yioPj7AKG53S9_U-Z_Q0t-gH_S7_N-3w';

console.log('Using Supabase URL:', supabaseUrl);
console.log('Using Service Role Key (Bypassing RLS)...');

const supabase = createClient(supabaseUrl, supabaseKey, {
    auth: {
        autoRefreshToken: false,
        persistSession: false
    }
});

async function debugBatches() {
    console.log('--- Debugging Missing Batches ---');

    // 1. Find the Item in menu_items (name is JSONB)
    console.log('Searching in menu_items...');

    // First try direct search in name->>ar
    let { data: items, error: itemError } = await supabase
        .from('menu_items')
        .select('id, name')
        .ilike('name->>ar', '%حليب بقري%')
        .limit(1);

    if (itemError) {
        console.error('Error fetching item:', itemError);
        return;
    }

    // If not found, try listing first few items to check structure
    if (!items || items.length === 0) {
        console.error('No item found matching "حليب بقري" in menu_items');

        console.log('Listing first 5 items to check structure:');
        const { data: allItems } = await supabase.from('menu_items').select('id, name').limit(5);
        console.log(JSON.stringify(allItems, null, 2));
        return;
    }

    const item = items[0];
    const nameAr = item.name?.ar || 'Unknown';
    const nameEn = item.name?.en || 'Unknown';
    console.log(`Found Item: ${nameAr} (${nameEn}) - ID: ${item.id}`);

    // 2. Check Stock Management
    const { data: stock, error: stockError } = await supabase
        .from('stock_management')
        .select('*')
        .eq('item_id', item.id);

    if (stockError) {
        console.error('Error fetching stock:', stockError);
    } else {
        console.log('\n--- Stock Management ---');
        console.table(stock);
    }

    // 3. Check Batches
    const { data: batches, error: batchError } = await supabase
        .from('batches')
        .select('*')
        .eq('item_id', item.id);

    if (batchError) {
        console.error('Error fetching batches:', batchError);
    } else {
        console.log('\n--- Batches ---');
        if (batches.length === 0) {
            console.log('No batches found for this item.');
        } else {
            console.table(batches.map(b => ({
                id: b.id,
                qty_rec: b.quantity_received,
                qty_con: b.quantity_consumed,
                rem_qty: (b.quantity_received || 0) - (b.quantity_consumed || 0),
                expiry: b.expiry_date,
                wh_id: b.warehouse_id,
                cost: b.unit_cost,
                created: b.created_at
            })));
        }
    }

    // 4. Check Inventory Movements (Purchase In)
    const { data: movements, error: mvError } = await supabase
        .from('inventory_movements')
        .select('*')
        .eq('item_id', item.id)
        .order('occurred_at', { ascending: false })
        .limit(10);

    if (mvError) {
        console.error('Error fetching movements:', mvError);
    } else {
        console.log('\n--- Recent Movements ---');
        console.table(movements.map(m => ({
            type: m.movement_type,
            qty: m.quantity,
            batch_id: m.batch_id,
            wh_id: m.warehouse_id,
            date: m.occurred_at
        })));
    }

    // 5. Check Warehouses
    const { data: warehouses, error: whError } = await supabase
        .from('warehouses')
        .select('*');

    if (whError) {
        console.error('Error fetching warehouses:', whError);
    } else {
        console.log('\n--- Warehouses ---');
        console.table(warehouses.map(w => ({ id: w.id, name: w.name })));
    }
}

debugBatches().catch(console.error);
