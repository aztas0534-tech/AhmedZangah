import https from 'https';
import fs from 'fs';
import path from 'path';

let envStr = '';
try {
    const envPath = path.resolve('c:/nasrflash/AhmedZ/.env.local');
    envStr = fs.readFileSync(envPath, 'utf8');
} catch (e) { process.exit(1); }

let url = '', key = '';
envStr.split('\n').forEach(line => {
    const [k, ...v] = line.split('=');
    const val = v.join('=').trim().replace(/"/g, '').replace(/'/g, '');
    if (k === 'VITE_SUPABASE_URL') url = val;
    if (k === 'VITE_SUPABASE_ANON_KEY') key = val;
});

const rpc = (q) => new Promise(resolve => {
    const reqUrl = new URL(url + '/rest/v1/rpc/exec_debug_sql');
    const options = {
        hostname: reqUrl.hostname, path: reqUrl.pathname,
        method: 'POST',
        headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json' }
    };
    const req = https.request(options, res => {
        let b = ''; res.on('data', d => b += d); res.on('end', () => resolve(b));
    });
    req.write(JSON.stringify({ q })); req.end();
});

async function run() {
    // Verify flour item now has correct stock
    const r1 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT sm.item_id, mi.name->>'ar' as name_ar,
           sm.available_quantity, sm.qc_hold_quantity, sm.reserved_quantity,
           w.name as warehouse_name
    FROM stock_management sm
    JOIN menu_items mi ON mi.id = sm.item_id
    JOIN warehouses w ON w.id = sm.warehouse_id
    WHERE mi.name->>'ar' LIKE '%دقيق القيم%'
  ) t;`);
    console.log('Flour stock after fix:', r1);

    // Check eggs too
    const r2 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT sm.item_id, mi.name->>'ar' as name_ar,
           sm.available_quantity, sm.qc_hold_quantity
    FROM stock_management sm
    JOIN menu_items mi ON mi.id = sm.item_id
    WHERE mi.name->>'ar' LIKE '%بيض كبير%'
  ) t;`);
    console.log('Egg stock after fix:', r2);

    // Count remaining mismatches
    const r3 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT count(*) as still_mismatched
    FROM stock_management sm
    WHERE sm.available_quantity = 0
      AND (SELECT coalesce(sum(greatest(
        coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)),0)
       FROM batches b WHERE b.item_id = sm.item_id::text AND b.warehouse_id = sm.warehouse_id
         AND coalesce(b.qc_status,'') = 'released'
         AND coalesce(b.status,'active') = 'active') > 0
  ) t;`);
    console.log('Remaining mismatches:', r3);
}

run();
