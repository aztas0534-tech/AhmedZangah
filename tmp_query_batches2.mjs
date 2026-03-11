import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.production', 'utf8'); } catch { try { envLocal = fs.readFileSync('.env', 'utf8'); } catch { } }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('VITE_SUPABASE_ANON_KEY=')) {
        supabaseKey = line.split('=')[1].trim();
    }
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const { data: batches, error } = await supabase
        .from('batches')
        .select(`
      id,
      item_id,
      quantity_received,
      unit_cost,
      created_at,
      receipt_id,
      purchase_receipts (
         id,
         purchase_order_id,
         purchase_orders (
            id,
            currency,
            fx_rate
         ),
         purchase_receipt_items (
            id,
            item_id,
            quantity,
            unit_cost,
            total_cost
         )
      )
    `)
        .order('created_at', { ascending: false })
        .limit(500);

    if (error) {
        console.error("Error:", error);
        return;
    }

    const targetIds = ['ca20926d', '793cae3c', '1b80d124'];
    const targets = batches.filter(b => targetIds.some(t => b.id.startsWith(t)));

    console.log(JSON.stringify(targets, null, 2));
}

run();
