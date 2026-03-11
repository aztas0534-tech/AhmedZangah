import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.production', 'utf8'); } catch { try { envLocal = fs.readFileSync('.env', 'utf8'); } catch { } }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const { data, error } = await supabase.rpc('diag_get_stuck_po_returns');

    if (error) {
        console.error("Error:", error);
        return;
    }

    const missingMovements = data.filter(r => !r.movement_qty);
    const missingJournals = data.filter(r => !r.journal_id);
    const zeroAmount = data.filter(r => r.movement_cost === 0 || r.journal_total_debit === 0);

    console.log(`Total Returns/Lines: ${data.length}`);
    console.log(`Missing Movements: ${missingMovements.length}`);
    if (missingMovements.length > 0) console.log(JSON.stringify(missingMovements, null, 2));

    console.log(`Missing Journals: ${missingJournals.length}`);
    if (missingJournals.length > 0) console.log(JSON.stringify(missingJournals, null, 2));

    console.log(`Zero Amount: ${zeroAmount.length}`);
    if (zeroAmount.length > 0) console.log(JSON.stringify(zeroAmount, null, 2));

}

run();
