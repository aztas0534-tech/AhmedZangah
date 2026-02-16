
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://pmhivhtaoydfolseelyc.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec'; // Prod Anon Key

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function run() {
    console.log('--- START DEBUGGING ---');

    // 1. Find the Item - List all to find the ID
    const { data: items, error: itemError } = await supabase
        .from('menu_items')
        .select('id, name')
        .limit(100);

    if (itemError) {
        console.error('Error fetching items:', itemError);
        return;
    }

    console.log('Found items:', items.length);
    items.forEach(i => console.log(`${i.id}: ${JSON.stringify(i.name)}`));

    // Stop here to let me pick the ID
    return;

    if (itemError) {
        console.error('Error fetching items:', itemError);
        return;
    }

    console.log('Found items:', items.length);
    if (items.length > 0) {
        console.log('First 5 items:', JSON.stringify(items.slice(0, 5), null, 2));
    }

    const targetItem = items.find(i =>
        JSON.stringify(i.name).includes('1400') || JSON.stringify(i.name).includes('Chicken') || JSON.stringify(i.name).includes('دجاج') || JSON.stringify(i.name).includes('Sera')
    );

    if (!targetItem) {
        console.log('Item not found via broad search. Listing first 5 items to check data structure:');
        console.log(items.slice(0, 5));
        return;
    }

    console.log('--- TARGET ITEM ---');
    console.log(JSON.stringify(targetItem, null, 2));

    const itemId = targetItem.id;

    // 2. Check Batches
    console.log('--- BATCHES ---');
    const { data: batches, error: batchError } = await supabase
        .from('batches')
        .select('*')
        .eq('item_id', itemId);

    if (batchError) {
        console.error('Error fetching batches:', batchError);
    } else {
        console.log(JSON.stringify(batches, null, 2));
    }

    // 3. Check Multi-Currency Prices
    console.log('--- PRODUCT PRICES MULTI CURRENCY ---');
    const { data: prices, error: priceError } = await supabase
        .from('product_prices_multi_currency')
        .select('*')
        .eq('item_id', itemId);

    if (priceError) {
        console.error('Error fetching prices:', priceError); // Table might not exist yet if migration failed?
    } else {
        console.log(JSON.stringify(prices, null, 2));
    }

    // 4. Check App Settings
    console.log('--- APP SETTINGS ---');
    const { data: settings, error: settingsError } = await supabase
        .from('app_settings')
        .select('*')
        .in('id', ['singleton', 'app']);

    if (settingsError) {
        console.error('Error fetching settings:', settingsError);
    } else {
        console.log(JSON.stringify(settings, null, 2));
    }

    console.log('--- END DEBUGGING ---');
}

run();
