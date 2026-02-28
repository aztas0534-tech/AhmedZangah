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
    console.log("Fetching Purchase Returns...");

    const { data: returns, error } = await supabase
        .from('purchase_returns')
        .select(`
      id,
      purchase_order_id,
      returned_at,
      created_by,
      reason,
      notes,
      created_at
    `)
        .order('created_at', { ascending: false })
        .limit(100);

    if (error) {
        console.error("Error fetching returns:", error);
        return;
    }

    const issues = [];
    let checked = 0;

    for (const ret of returns) {
        checked++;

        const { data: movements } = await supabase
            .from('inventory_movements')
            .select('id')
            .eq('reference_table', 'purchase_returns')
            .eq('reference_id', ret.id)
            .limit(1);

        const { data: journals } = await supabase
            .from('journal_entries')
            .select('id')
            .eq('source_table', 'purchase_returns')
            .eq('source_id', ret.id)
            .limit(1);

        const hasMovement = movements && movements.length > 0;
        const hasJournal = journals && journals.length > 0;

        if (!hasMovement || !hasJournal) {
            issues.push({
                id: ret.id,
                po_id: ret.purchase_order_id,
                date: ret.created_at,
                hasMovement,
                hasJournal
            });
        }
    }

    console.log(`Checked ${checked} valid returns. Found ${issues.length} stuck returns:`);
    if (issues.length > 0) {
        console.log(JSON.stringify(issues, null, 2));
    }
}

run();
