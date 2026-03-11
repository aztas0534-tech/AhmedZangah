const { Client } = require('pg');

const client = new Client({
    connectionString: 'postgres://postgres:AhmadZangah1%23123455@db.pmhivhtaoydfolseelyc.supabase.co:5432/postgres',
    ssl: { rejectUnauthorized: false }
});

async function run() {
    await client.connect();
    console.log("Connected directly to Postgres!");

    try {
        const shiftsRes = await client.query(`
      SELECT s.id, s.cashier_id, s.opened_at, s.closed_at, s.status, s.start_amount, s.end_amount, s.expected_amount, s.difference, s.tender_counts, s.difference_json, p.email 
      FROM public.cash_shifts s
      LEFT JOIN public.profiles p ON p.id = s.cashier_id
      ORDER BY s.opened_at DESC
      LIMIT 10
    `);

        if (shiftsRes.rows.length === 0) {
            console.log('No shifts found in the database. Are you sure this is the right environment?');
            return;
        }

        console.log(`\n--- RECENT SHIFTS ---`);
        for (const shift of shiftsRes.rows) {
            console.log(`\n###########################################`);
            console.log(`Shift ID: ${shift.id.split('-')[0]}...`);
            console.log(`Cashier: ${shift.email || shift.cashier_id}`);
            console.log(`Status: ${shift.status}`);
            console.log(`Opened: ${new Date(shift.opened_at).toLocaleString('en-US', { timeZone: 'Asia/Riyadh' })}`);
            if (shift.closed_at) {
                console.log(`Closed: ${new Date(shift.closed_at).toLocaleString('en-US', { timeZone: 'Asia/Riyadh' })}`);
            }
            console.log(`Expected: ${shift.expected_amount}, End: ${shift.end_amount}, Diff: ${shift.difference}`);
            if (shift.difference_json) console.log(`Multicurrency Diff:`, JSON.stringify(shift.difference_json));

            const paymentsRes = await client.query(`
        SELECT method, direction, SUM(COALESCE(base_amount, amount)) as total_base
        FROM public.payments
        WHERE shift_id = $1
        GROUP BY method, direction
      `, [shift.id]);

            let cashIn = 0; let cashOut = 0;
            paymentsRes.rows.forEach(p => {
                const amt = Number(p.total_base);
                if (p.method === 'cash') {
                    if (p.direction === 'in') cashIn += amt;
                    if (p.direction === 'out') cashOut += amt;
                }
            });
            console.log(`Payments -> Cash In: ${cashIn.toFixed(2)}, Cash Out: ${cashOut.toFixed(2)}`);

            // Check for missing orders
            const ordersRes = await client.query(`
        SELECT id, created_at, status, data
        FROM public.orders
        WHERE created_by = $1
          AND created_at >= $2
          AND created_at <= COALESCE($3, NOW())
          AND status IN ('completed', 'preparing', 'ready')
      `, [shift.cashier_id, shift.opened_at, shift.closed_at]);

            const orderIds = ordersRes.rows.map(o => o.id);

            let missingOrders = [];
            if (orderIds.length > 0) {
                const linkedPaymentsRes = await client.query(`
          SELECT reference_id, SUM(COALESCE(base_amount, amount)) as payment_total
          FROM public.payments
          WHERE reference_table = 'orders'
            AND reference_id = ANY($1)
          GROUP BY reference_id
        `, [orderIds]);

                const linkedIds = new Set(linkedPaymentsRes.rows.map(p => p.reference_id));
                for (const o of ordersRes.rows) {
                    if (!linkedIds.has(o.id)) {
                        missingOrders.push(o);
                    }
                }
            }

            console.log(`Total Orders in Time Window: ${orderIds.length}`);
            console.log(`[!] Orders Missing Payments: ${missingOrders.length}`);
            if (missingOrders.length > 0) {
                missingOrders.slice(0, 3).forEach(mo => {
                    console.log(`    Missing Order: ${mo.id.split('-')[0]}, Created: ${new Date(mo.created_at).toISOString()}, Total: ${mo.data?.total}`);
                });
            }
        }

    } catch (e) {
        console.error('DB Error:', e);
    } finally {
        await client.end();
    }
}

run();
