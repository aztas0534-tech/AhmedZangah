
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials from debug_pricing.mjs
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz'; // Service Role Key

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function findLandedCostEntry() {
    console.log('--- Searching for Landed Cost Entry ---');

    // Searching by the specific amount from the screenshot: 70,571,974.30
    // or close to it to account for floating point
    const targetAmount = 70571974.30;

    const { data: lines, error } = await supabase
        .from('journal_lines')
        .select(`
      id, 
      debit, 
      credit, 
      currency_code, 
      fx_rate, 
      foreign_amount,
      journal_entry:journal_entries (
        id, 
        entry_date, 
        memo, 
        source_table, 
        source_id,
        source_event
      )
    `)
        .or(`debit.eq.${targetAmount},credit.eq.${targetAmount}`);

    if (error) {
        console.error('Error searching:', error);
        return;
    }

    if (lines && lines.length > 0) {
        console.log('Found Suspect Entries:');
        console.log(JSON.stringify(lines, null, 2));
    } else {
        console.log('No exact match found. Trying broader search by memo...');

        const { data: entries, error: eError } = await supabase
            .from('journal_entries')
            .select('*')
            .ilike('memo', '%Import landed cost%')
            .order('entry_date', { ascending: false })
            .limit(3);

        if (eError) {
            console.error('Error searching by memo:', eError);
        } else {
            console.log('Recent Landed Cost Entries:', JSON.stringify(entries, null, 2));
        }
    }
}

findLandedCostEntry();
