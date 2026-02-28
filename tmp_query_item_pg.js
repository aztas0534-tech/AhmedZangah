const { Client } = require('pg');

const client = new Client({
    connectionString: 'postgresql://postgres.pmhivhtaoydfolseelyc@aws-1-ap-south-1.pooler.supabase.com:5432/postgres',
});

async function run() {
    await client.connect();
    try {
        const res = await client.query("select id from public.menu_items where name->>'ar' like '%ماء طيبة صغير%' limit 1");
        if (res.rowCount === 0) { console.log('Item not found'); return; }

        const itemId = res.rows[0].id;
        console.log('Item ID:', itemId);

        const sm = await client.query("select available_quantity, qc_hold_quantity, reserved_quantity, avg_cost from public.stock_management where item_id = $1", [itemId]);
        console.log('\n--- Stock Management System-Wide ---');
        console.dir(sm.rows, { depth: null });

        const batches = await client.query("select id, quantity_received, quantity_consumed, status, qc_status, unit_cost from public.batches where item_id = $1", [itemId]);
        console.log('\n--- Batches Record ---');
        console.dir(batches.rows, { depth: null });

        const movements = await client.query("select id, batch_id, movement_type, quantity, unit_cost, reference_table, occurred_at, data from public.inventory_movements where item_id = $1 order by occurred_at asc", [itemId]);
        console.log('\n--- Inventory Movements Log ---');
        console.dir(movements.rows, { depth: null });

        const batchBalances = await client.query("select batch_id, quantity from public.batch_balances where item_id = $1", [itemId]);
        console.log('\n--- Batch Balances Live Table ---');
        console.dir(batchBalances.rows, { depth: null });

        const returns = await client.query("select pri.id, pri.purchase_order_id, pri.quantity, pri.unit_cost from public.purchase_return_items pri where pri.item_id = $1", [itemId]);
        console.log('\n--- Return Items specifically for this Item ---');
        console.dir(returns.rows, { depth: null });
    } finally {
        await client.end();
    }
}
run();
