import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://pmhivhtaoydfolseelyc.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false }
});

async function run() {
    console.log('Logging in...');
    const { data: authData, error: authErr } = await supabase.auth.signInWithPassword({
        email: 'owner@azta.com',
        password: 'AhmedZ#123456'
    });

    if (authErr) {
        console.error('Login failed:', authErr.message);
        return;
    }
    console.log('Logged in successfully as', authData.user.id);

    let { data: shift } = await supabase.from('cash_shifts').select('id').eq('status', 'open').eq('cashier_id', authData.user.id).single();
    if (!shift) {
        console.log('No open shift found. Creating a temporary one...');
        const { data: newShift, error: shiftErr } = await supabase.from('cash_shifts').insert({
            cashier_id: authData.user.id,
            start_amount: 0,
            status: 'open'
        }).select('id').single();
        if (shiftErr) {
            console.error('Failed to create shift:', shiftErr);
            return;
        }
        shift = newShift;
        console.log('Created new shift:', shift.id);
    }

    // 2 & 3. Fetch items with stock from different warehouses dynamically
    console.log('Finding items that exist in multiple warehouses...');
    const { data: stockData, error: stockErr } = await supabase
        .from('batches')
        .select('item_id, warehouse_id')
        .limit(1000);
        
    if (stockErr || !stockData || stockData.length === 0) {
        console.error('Could not fetch stock data:', stockErr);
        return;
    }

    // Group by warehouse_id instead
    const whMap = new Map();
    for (const row of stockData) {
        if (!whMap.has(row.warehouse_id)) whMap.set(row.warehouse_id, row.item_id);
    }
    
    const items = [];
    if (whMap.size >= 2) {
        const whEntries = Array.from(whMap.entries());
        for (let i = 0; i < 2; i++) {
            const [whId, itemId] = whEntries[i];
            const { data: itemData } = await supabase
                .from('menu_items')
                .select('id, name, sale_price')
                .eq('id', itemId)
                .single();
            if (itemData) {
                items.push({ ...itemData, warehouseId: whId });
            }
        }
    }

    if (items.length < 2) {
        console.log('Could not find enough distinct warehouses in the sample of 1000 batches.');
        return;
    }
    
    console.log('Using items:', items.map(i => `${i.name?.ar || i.name} (from warehouse ${i.warehouseId})`));

    console.log('Creating base order...');
    const nowIso = new Date().toISOString();
    const orderData = {
        customer_name: 'Test Multi-Warehouse Sale',
        phone_number: '0000000000',
        subtotal: items[0].sale_price + (items[1]?.sale_price || 0),
        total: items[0].sale_price + (items[1]?.sale_price || 0),
        status: 'pending',
        payment_method: 'cash',
        delivery_zone_id: '52be2723-b97b-40ad-a7c6-f816b0a02e08',
        data: { orderSource: 'in_store' },
        created_at: nowIso,
        items: items.map((item) => ({
            id: String(item.id),
            name: { ar: item.name },
            price: item.sale_price,
            quantity: 1,
            warehouseId: item.warehouseId
        }))
    };

    const { data: newOrder, error: orderErr } = await supabase.from('orders').insert(orderData).select('id').single();
    if (orderErr) {
        console.error('Failed to insert base order:', orderErr);
        return;
    }
    console.log('Inserted base order:', newOrder.id);

    // 5. Build RPC payload
    const payloadItems = items.map((item) => ({
        itemId: String(item.id),
        quantity: 1,
        uomQtyInBase: 1,
        warehouseId: item.warehouseId
    }));

    const updatedData = {
        ...orderData,
        status: 'delivered',
        paidAt: nowIso,
        deliveredAt: nowIso
    };

    const args = {
        p_order_id: newOrder.id,
        p_items: payloadItems,
        p_updated_data: updatedData,
        p_warehouse_id: warehouses[0].id
    };

    console.log('Calling confirm_order_delivery_with_credit...');
    const { data: confirmData, error: confirmErr } = await supabase.rpc('confirm_order_delivery_with_credit', args);

    if (confirmErr) {
        console.error('RPC Error:', confirmErr);
    } else {
        console.log('Successfully completed multi-warehouse sale!', confirmData);
    }
}

run();
