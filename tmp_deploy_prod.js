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
    const sql = fs.readFileSync('supabase/migrations/20260228054000_restore_post_inventory_movement_full.sql', 'utf8');
    // Need to use an RPC that can execute arbitrary SQL since supabase-js does not support direct SQL queries.
    // There is an 'execute_sql' rpc we discovered earlier. Let's try it.
    const { data, error } = await supabase.rpc('execute_sql', { sql: sql });
    console.log('Result:', data);
    console.log('Error:', error);
}

run();
