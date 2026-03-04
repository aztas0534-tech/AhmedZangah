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
    // Check second trigger definition
    const r1 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT p.proname, p.prosrc
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' AND p.proname = 'trg_forbid_update_posted_orders_amounts'
  ) t;`);
    console.log('Second trigger:', r1);

    // Check void_delivered_order function signature
    const r2 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT p.proname, pg_get_function_arguments(p.oid) as args
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' AND p.proname = 'void_delivered_order'
  ) t;`);
    console.log('void_delivered_order args:', r2);
}

run();
