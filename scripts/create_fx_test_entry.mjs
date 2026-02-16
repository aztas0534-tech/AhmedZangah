
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials from debug_pricing.mjs
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz'; // Service Role Key

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function createFxTestEntry() {
    console.log('--- Creating Test FX Journal Entry (Authenticated RPC Mode) ---');

    // 1. Authenticate as Owner
    const EMAIL = 'owner@azta.com';
    const PASSWORD = 'Owner@123';

    console.log(`Authenticating as ${EMAIL}...`);
    const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
        email: EMAIL,
        password: PASSWORD
    });

    if (authError) {
        console.error('Authentication Failed:', authError);
        return;
    }

    console.log('Authentication Successful. User ID:', authData.user.id);

    // 2. Prepare Payload
    const foreignAmount = 100.00;
    const fxRate = 3.755;
    const baseAmount = foreignAmount * fxRate;
    const currencyCode = 'USD';

    const lines = [
        {
            accountCode: '2010', // Payable
            debit: 0,
            credit: baseAmount,
            memo: 'Test FX Credit (Script)',
            currencyCode: currencyCode,
            fxRate: fxRate,
            foreignAmount: foreignAmount
        },
        {
            accountCode: '1010', // Cash
            debit: baseAmount,
            credit: 0,
            memo: 'Test FX Debit (Script)',
            currencyCode: currencyCode,
            fxRate: fxRate,
            foreignAmount: foreignAmount
        }
    ];

    console.log('Payload:', JSON.stringify(lines, null, 2));

    // 3. Call RPC
    const { data, error } = await supabase.rpc('create_manual_journal_entry', {
        p_entry_date: new Date().toISOString(),
        p_memo: 'Test FX Entry - Script Generation',
        p_lines: lines,
        p_journal_id: null // Default
    });

    if (error) {
        console.error('Error calling RPC:', error);
    } else {
        console.log('Successfully created FX Test Entry via RPC!');
        console.log(`Entry ID: ${data}`);
        console.log(`Please verify this ID in the UI.`);
    }
}

createFxTestEntry();
