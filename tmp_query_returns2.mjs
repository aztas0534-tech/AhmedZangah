import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch { try { envLocal = fs.readFileSync('.env', 'utf8'); } catch { } }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
    else if (!supabaseKey && line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    console.log("== Checking Purchase Receipts (Negative Qty?) ==");
    const { data: pr, error: prErr } = await supabase.from('purchase_receipt_items').select('*').lt('quantity', 0).limit(5);
    console.log(pr || prErr);

    console.log("\n== Checking Inventory Movements (return_in/return_out) ==");
    const { data: sr, error: srErr } = await supabase.from('inventory_movements').select('id, movement_type, reference_table, occurred_at').in('movement_type', ['return_in', 'return_out']).order('occurred_at', { ascending: false }).limit(10);
    console.log(sr || srErr);

    console.log("\n== Checking Any Purchase Orders with hasReturns ==");
    const { data: por, error: porErr } = await supabase.from('purchase_orders').select('id, status, has_returns').eq('has_returns', true).limit(5);
    console.log(por || porErr);
}

run();
