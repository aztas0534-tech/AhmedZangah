
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';

console.log('🔌 Connecting to Supabase...');
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: { persistSession: false }
});

async function runAudit() {
    console.log('🚀 Starting Sales Data Audit...');

    // 1. Get Base Currency
    const { data: baseCurrencyData, error: baseError } = await supabase.rpc('get_base_currency');
    if (baseError) {
        console.error('❌ Failed to get base currency:', baseError);
        return;
    }
    const baseCurrency = baseCurrencyData || 'YER'; // Default fallback
    console.log(`ℹ️ Base Currency: ${baseCurrency}`);

    // 2. Check Orders Integrity
    console.log('\n🔍 Checking Order Integrity...');
    const { data: orders, error: ordersError } = await supabase
        .from('orders')
        .select('id, status, currency, fx_rate, base_total, total, data')
        .eq('status', 'delivered'); // Focus on delivered orders for COGS

    if (ordersError) {
        console.error('❌ Failed to fetch orders:', ordersError);
        return;
    }

    let missingBaseTotal = 0;
    let suspiciousFx = 0;
    let missingCogs = 0;
    let cogsMismatch = 0;
    let checkedCogs = 0;

    console.log(`ℹ️ Analyzing ${orders.length} delivered orders...`);

    for (const order of orders) {
        // Check Base Total
        if (order.base_total === null || order.base_total === undefined) {
            missingBaseTotal++;
        }

        // Check FX Rate
        const orderCurrency = order.currency || order.data?.currency || baseCurrency;
        if (orderCurrency !== baseCurrency && (order.fx_rate === 1 || !order.fx_rate)) {
            suspiciousFx++;
        }

        // Check COGS (order_item_cogs)
        const { data: cogsData, error: cogsError } = await supabase
            .from('order_item_cogs')
            .select('total_cost')
            .eq('order_id', order.id);

        if (cogsError) {
            console.error(`❌ Error fetching COGS for order ${order.id}:`, cogsError);
            continue;
        }

        if (!cogsData || cogsData.length === 0) {
            // Double check if there are any items. If it's a test order with no items, maybe acceptable?
            // But status is delivered.
            const items = order.data?.items || order.data?.invoiceSnapshot?.items || [];
            if (items.length > 0) {
                missingCogs++;
                // console.log(`⚠️ Order ${order.id} missing COGS. Items: ${items.length}`);
            }
        } else {
            // Compare with Inventory Movements (Sample check - first 50 orders only to save time/RPC calls if we were doing it via RPC, but here we query individually so maybe slow)
            // We will just sum cogsData.
            const cogsSum = cogsData.reduce((acc, row) => acc + (Number(row.total_cost) || 0), 0);

            // We assume valid COGS if > 0.
            if (cogsSum <= 0) {
                // console.log(`⚠️ Order ${order.id} has 0 COGS but exists in table.`);
            }
        }
    }

    console.log('\n📊 Audit Results (Delivered Orders Only):');
    console.log(`   Total Delivered:    ${orders.length}`);
    console.log(`   Missing Base Total: ${missingBaseTotal} ${missingBaseTotal > 0 ? '❌' : '✅'}`);
    console.log(`   Suspicious FX Rate: ${suspiciousFx} ${suspiciousFx > 0 ? '⚠️' : '✅'} (Non-base currency with rate 1)`);
    console.log(`   Missing COGS Rows:  ${missingCogs} ${missingCogs > 0 ? '❌ CRITICAL: Profit Profitability Inflated' : '✅'}`);

    if (missingCogs > 0) {
        console.log('\nSuggested Action: Run a backfill script to populate order_item_cogs from inventory_movements or recalculate from recipes.');
    }

    // 3. Sample COGS Mismatch Check (Limit to recent 5 orders)
    console.log('\n🔍 Detailed COGS Verification (Recent 5 Orders)...');
    const recentOrders = orders.slice(0, 5);
    for (const order of recentOrders) {
        const { data: cogsData } = await supabase.from('order_item_cogs').select('total_cost').eq('order_id', order.id);
        const cogsSum = cogsData?.reduce((acc, row) => acc + Number(row.total_cost), 0) || 0;

        const { data: movements } = await supabase
            .from('inventory_movements')
            .select('total_cost')
            .eq('reference_table', 'orders')
            .eq('reference_id', order.id)
            .eq('movement_type', 'sale_out');

        const movementSum = movements?.reduce((acc, row) => acc + Math.abs(Number(row.total_cost)), 0) || 0; // Movements usually negative for out, so abs.

        const diff = Math.abs(cogsSum - movementSum);
        if (diff > 0.01) {
            console.log(`⚠️ Mismatch Order ${order.id.slice(0, 8)}... COGS Table: ${cogsSum.toFixed(2)}, Movements: ${movementSum.toFixed(2)}, Diff: ${diff.toFixed(2)}`);
        } else {
            console.log(`✅ Order ${order.id.slice(0, 8)}... OK`);
        }
    }

}

runAudit().catch(err => console.error(err));
