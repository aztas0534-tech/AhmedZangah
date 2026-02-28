import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.production', 'utf8'); } catch { try { envLocal = fs.readFileSync('.env', 'utf8'); } catch { } }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('VITE_SUPABASE_ANON_KEY=')) {
        // using anon key because we only want to read
        supabaseKey = line.split('=')[1].trim();
    }
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) {
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
      purchase_receipts:receipt_id (
         id,
         purchase_order_id,
         purchase_orders:purchase_order_id (
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
        .or('id.ilike.ca20926d-%,id.ilike.793cae3c-%,id.ilike.1b80d124-%');

    if (error) {
        console.error("Error:", error);
        return;
    }

    console.log(JSON.stringify(batches, null, 2));
}

run();
