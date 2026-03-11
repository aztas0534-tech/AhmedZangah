import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
let envProd = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch { }
try { envProd = fs.readFileSync('.env.production', 'utf8'); } catch { }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envProd.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
}
for (const line of envLocal.split('\n')) {
    if (!supabaseUrl && line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const pos = [
        'PO-MAIN-2026-000002',
        'PO-MAIN-2026-000003',
        'PO-MAIN-2026-000012',
        'PO-MAIN-2026-000031'
    ];
    const { data, error } = await supabase.rpc('diag_analyze_specific_pos', { po_numbers: pos });

    if (error) {
        console.error("Error:", error);
        return;
    }

    console.log(JSON.stringify(data, null, 2));
}

run();
