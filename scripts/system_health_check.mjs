
import { createClient } from '@supabase/supabase-js';

// Hardcoded credentials for quick debugging
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function runHealthCheck() {
    console.log('╔════════════════════════════════════╗');
    console.log('║      SYSTEM HEALTH CHECK           ║');
    console.log('╚════════════════════════════════════╝');
    console.log('Checking for Foreign Currency & Landed Cost Anomalies...\n');

    const anomalies = {
        bad_fx_batches: 0,
        bad_cost_batches: 0,
        huge_journals: 0,
        missing_foreign_data: 0
    };

    // 1. Check for Batches with Missing FX Rate (Foreign Currency but FX = 1)
    // We assume 'SAR' is base for this check, or we check if currency != 'SAR'
    const { data: badFxBatches, error: fxError } = await supabase
        .from('batches')
        .select('id, foreign_currency, fx_rate_at_receipt')
        .neq('foreign_currency', 'SAR')
        .eq('fx_rate_at_receipt', 1)
        .not('foreign_currency', 'is', null);

    if (fxError) console.error('Error checking FX Batches:', fxError.message);
    else {
        anomalies.bad_fx_batches = badFxBatches.length;
        console.log(`[${badFxBatches.length > 0 ? 'FAIL' : 'PASS'}] Batches with Foreign Currency but FX Rate = 1: ${badFxBatches.length}`);
    }

    // 2. Check for Batches with Massive Cost Discrepancy (Cost > 1M usually indicates YER mixed with SAR)
    const { data: hugeCostBatches, error: costError } = await supabase
        .from('batches')
        .select('id, unit_cost')
        .gt('unit_cost', 1000000); // 1 Million SAR unit cost is likely an error

    if (costError) console.error('Error checking Huge Cost Batches:', costError.message);
    else {
        anomalies.bad_cost_batches = hugeCostBatches.length;
        console.log(`[${hugeCostBatches.length > 0 ? 'FAIL' : 'PASS'}] Batches with Suspicious Unit Cost (> 1M): ${hugeCostBatches.length}`);
    }

    // 3. Check for Massive Journal Entries (> 10M)
    const { data: hugeJournals, error: jeError } = await supabase
        .from('journal_lines')
        .select('id, debit, credit, journal_entry_id')
        .or('debit.gt.10000000,credit.gt.10000000'); // 10 Million

    if (jeError) console.error('Error checking Journal Entries:', jeError.message);
    else {
        anomalies.huge_journals = hugeJournals.length;
        console.log(`[${hugeJournals.length > 0 ? 'FAIL' : 'PASS'}] Journal Lines with Amount > 10M: ${hugeJournals.length}`);
        if (hugeJournals.length > 0) {
            console.log('    -> IDs:', hugeJournals.map(j => j.journal_entry_id).join(', '));
        }
    }

    console.log('\n--------------------------------------');
    console.log('SUMMARY:');
    if (Object.values(anomalies).some(v => v > 0)) {
        console.log('❌ SYSTEM HAS POTENTIAL ANOMALIES. PLEASE RUN FIX SCRIPTS.');
        console.log('Recommended Actions:');
        if (anomalies.bad_fx_batches > 0 || anomalies.bad_cost_batches > 0) {
            console.log(' - Run: node scripts/apply_migration.mjs (to apply fix_production_batch_costs.sql if wrapped) OR better:');
            console.log(' - Run SQL: scripts/fix_production_batch_costs.sql');
        }
        if (anomalies.huge_journals > 0) {
            console.log(' - Run SQL: scripts/fix_historical_landed_costs.sql');
        }
    } else {
        console.log('✅ SYSTEM LOOKS HEALTHY (Based on these checks).');
    }
    console.log('--------------------------------------');
}

runHealthCheck();
