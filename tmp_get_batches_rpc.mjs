import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envProd = '';
try { envProd = fs.readFileSync('.env.production', 'utf8'); } catch { }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envProd.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
}
let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch { }
for (const line of envLocal.split('\n')) {
    if (!supabaseUrl && line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const { data, error } = await supabase.rpc('execute_sql', {
        sql: `SELECT prosrc FROM pg_proc WHERE proname = 'get_item_batches'`
    });
    if (error) {
        console.error(error);
    } else {
        console.log(data);
    }
}
run();
