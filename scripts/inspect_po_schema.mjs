
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function inspectPoSchema() {
    console.log('--- Inspecting PO Schema & Data ---');

    const { data: po, error } = await supabase
        .from('purchase_orders')
        .select('*')
        .neq('currency', 'SAR')
        .limit(1);

    if (error) {
        console.error('Error:', error);
        return;
    }

    if (po && po.length > 0) {
        console.log('Found Foreign PO:');
        const p = po[0];
        console.log(`ID: ${p.id}`);
        console.log(`Currency: ${p.currency}`);
        console.log(`Exchange Rate: ${p.exchange_rate}`); // Column might be named differently
        console.log(`FX Rate: ${p.fx_rate}`); // Alternative name
        console.log('All keys:', Object.keys(p));
    } else {
        console.log('No foreign PO found, trying SAR PO...');
        const { data: poSar } = await supabase.from('purchase_orders').select('*').limit(1);
        if (poSar && poSar.length > 0) {
            console.log('All keys (SAR PO):', Object.keys(poSar[0]));
        }
    }
}

inspectPoSchema();
