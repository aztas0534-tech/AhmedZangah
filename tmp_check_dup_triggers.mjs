import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envProd = '';
try { envProd = fs.readFileSync('.env.production', 'utf8'); } catch { }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envProd.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('VITE_SUPABASE_ANON_KEY=')) {
        supabaseKey = line.split('=')[1].trim();
    }
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const { data, error } = await supabase.rpc('diag_list_triggers');

    if (error) {
        console.error("Error:", error);
        return;
    }

    const triggers = data.filter(t => t.table_name === 'inventory_movements' && t.function_name.includes('purchase_in_sync_batch'));
    console.log(JSON.stringify(triggers, null, 2));
}

run();
