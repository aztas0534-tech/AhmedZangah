import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch { }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) {
        supabaseKey = line.split('=')[1].trim();
    }
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const { data, error } = await supabase.from('batches').select(`
    id, quantity_received, quantity_consumed, receipt_id,
    purchase_receipts(purchase_order_id)
  `).in('id', [
        'ca20926d-9e9c-442a-8662-926e7232d50d',
        '793cae3c-1057-48b5-a36b-af21a9f33dc4',
        '1b80d124-6813-4f6c-b6a7-143fd836addf'
    ]);

    if (error) {
        console.error("Error:", error);
        return;
    }

    console.log(JSON.stringify(data, null, 2));
}

run();
