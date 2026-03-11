import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch { try { envLocal = fs.readFileSync('.env', 'utf8'); } catch { } }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const { data, error } = await supabase.rpc('execute_sql', {
        sql: `SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'trg_purchase_orders_fx_lock';`
    });
    console.log(data || error);
}
run();
