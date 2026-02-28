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
    console.log("== Purchase Returns ==");
    const { data: pr } = await supabase.from('purchase_returns').select('*').order('created_at', { ascending: false }).limit(5);
    console.log(pr);

    console.log("\n== Sales Returns ==");
    const { data: sr } = await supabase.from('sales_returns').select('id, status, created_at').order('created_at', { ascending: false }).limit(5);
    console.log(sr);
}

run();
