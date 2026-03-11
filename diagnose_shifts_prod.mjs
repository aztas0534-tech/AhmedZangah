import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://pmhivhtaoydfolseelyc.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

async function checkShifts() {
    console.log('Fetching the last 10 closed shifts...');
    const { data: shifts, error: shiftsError } = await supabase
        .from('cash_shifts')
        .select('*')
        .order('opened_at', { ascending: false })
        .limit(10);

    if (shiftsError) {
        console.error('Error fetching shifts:', shiftsError);
        return;
    }

    if (!shifts || shifts.length === 0) {
        console.log('No closed shifts found.');
        return;
    }

    for (const shift of shifts) {
        console.log(`\n===========================================`);
        console.log(`Shift ID: ${shift.id}`);
        console.log(`Cashier ID: ${shift.cashier_id}`);
        console.log(`Opened: ${new Date(shift.opened_at).toLocaleString()}`);
        console.log(`Closed: ${new Date(shift.closed_at).toLocaleString()}`);
        console.log(`Start Amount: ${shift.start_amount}`);
        console.log(`Expected Cash: ${shift.expected_amount}`);
        console.log(`Actual Cash (End Amount): ${shift.end_amount}`);
        const diff = Number(shift.end_amount) - Number(shift.expected_amount);
        console.log(`Difference: ${diff.toFixed(2)} (${shift.difference})`);
        if (shift.forced_close) {
            console.log(`[!] Forced Close Reason: ${shift.forced_close_reason}`);
        }

        if (shift.tender_counts) {
            console.log(`Tender Counts:`, JSON.stringify(shift.tender_counts));
        }
        if (shift.difference_json) {
            console.log(`Difference (Multi-c):`, JSON.stringify(shift.difference_json));
        }

        // Fetch payments for this shift
        const { data: payRows } = await supabase
            .from('payments')
            .select('id, method, amount, currency, direction, base_amount, reference_table, occurred_at')
            .eq('shift_id', shift.id);

        let cashIn = 0;
        let cashOut = 0;
        let otherIn = 0;
        let otherOut = 0;
        let orderPayments = 0;
        let returnPayments = 0;

        for (const p of (payRows || [])) {
            const amt = Number(p.base_amount ?? p.amount);
            if (p.method === 'cash') {
                if (p.direction === 'in') cashIn += amt;
                if (p.direction === 'out') cashOut += amt;
            } else {
                if (p.direction === 'in') otherIn += amt;
                if (p.direction === 'out') otherOut += amt;
            }
            if (p.reference_table === 'orders') orderPayments++;
            if (p.reference_table === 'sales_returns') returnPayments++;
        }

        console.log(`--- Payments summary ---`);
        console.log(`Cash In: ${cashIn.toFixed(2)}, Cash Out: ${cashOut.toFixed(2)}`);
        console.log(`Other In: ${otherIn.toFixed(2)}, Other Out: ${otherOut.toFixed(2)}`);
        console.log(`Order Payments count: ${orderPayments}, Return Payments count: ${returnPayments}`);

        // Let's check if there are any completed orders during this shift's time window that ARE NOT in payments
        const { data: orders } = await supabase
            .from('orders')
            .select('id, data, currency, base_total, total')
            .eq('created_by', shift.cashier_id)
            .gte('created_at', shift.opened_at)
            .lte('created_at', shift.closed_at)
            .in('status', ['completed']);

        let totalOrderValue = 0;
        const missingFromPayments = [];

        const payOrderIds = new Set((payRows || []).filter(p => p.reference_table === 'orders').map(p => p.data?.orderId || p.reference_id));

        for (const o of (orders || [])) {
            const oTotal = Number(o.base_total ?? o.total ?? o.data?.total ?? 0);
            totalOrderValue += oTotal;
            if (!payOrderIds.has(o.id)) {
                missingFromPayments.push(o.id);
            }
        }

        console.log(`Total orders during shift (completed): ${orders?.length || 0}`);
        console.log(`Orders missing from payments table: ${missingFromPayments.length}`);
        if (missingFromPayments.length > 0) {
            console.log(`Missing order IDs (first 5):`, missingFromPayments.slice(0, 5));
        }

    }
}

checkShifts().catch(console.error);
