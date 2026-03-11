import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try {
    envLocal = fs.readFileSync('.env.local', 'utf8');
} catch {
    envLocal = fs.readFileSync('.env', 'utf8');
}

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
    else if (!supabaseKey && line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

console.log('Using URL:', supabaseUrl);
console.log('Is Service Role Key:', supabaseKey.length > 100);

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const { data: allRet, error: retErr } = await supabase.from('sales_returns').select('id, order_id, status, refund_method, total_refund_amount, created_at').order('created_at', { ascending: false });
    if (retErr) {
        console.error(retErr);
        return;
    }

    const target = allRet.find(r => r.id.toLowerCase().endsWith('d11611'));
    console.log('Target Return:', target);

    if (target) {
        const { data: je, error: jeErr } = await supabase.from('journal_entries').select('id, source_table, source_id, source_event, status').eq('source_table', 'sales_returns').eq('source_id', target.id).maybeSingle();
        console.log('Journal Entry:', je, jeErr);
        if (je) {
            const { data: lines, error: lineErr } = await supabase.from('journal_lines').select('id, account_id, debit, credit, line_memo').eq('journal_entry_id', je.id);
            console.log('Journal Lines:', lines, lineErr);
        }
    } else {
        console.log('Last 5 returns:', allRet.slice(0, 5));
    }
}
run();
