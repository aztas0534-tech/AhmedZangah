
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials from debug_pricing.mjs
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz'; // Service Role Key

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function findFxEntry() {
    console.log('Searching for journal entries with foreign currency...');

    // Try to find headers with currency_code != 'SAR'
    const { data: headers, error: hError } = await supabase
        .from('journal_entries')
        .select('id, entry_date, memo, currency_code, fx_rate, foreign_amount')
        .neq('currency_code', 'SAR')
        .not('currency_code', 'is', null)
        .order('created_at', { ascending: false })
        .limit(5);

    if (hError) {
        console.error('Error fetching headers:', hError);
    } else if (headers && headers.length > 0) {
        console.log('Found Journal Entries (Header Level):');
        console.table(headers);
    } else {
        console.log('No headers found with foreign currency. Checking lines...');
    }

    // Try to find lines with currency_code != 'SAR'
    const { data: lines, error: lError } = await supabase
        .from('journal_lines')
        .select('journal_entry_id, account_id, debit, credit, currency_code, fx_rate, foreign_amount')
        .neq('currency_code', 'SAR')
        .not('currency_code', 'is', null)
        .limit(5);

    if (lError) {
        console.error('Error fetching lines:', lError);
    } else if (lines && lines.length > 0) {
        console.log('Found Journal Lines (Line Level):');
        console.table(lines);
    } else {
        console.log('No foreign currency entries found in headers or lines.');
    }
}

findFxEntry();
