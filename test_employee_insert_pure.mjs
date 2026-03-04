import https from 'https';
import fs from 'fs';
import path from 'path';

let envStr = '';
try {
    const envPath = path.resolve('c:/nasrflash/AhmedZ/.env.local');
    envStr = fs.readFileSync(envPath, 'utf8');
} catch (e) {
    process.exit(1);
}

let url = '';
let key = '';

envStr.split('\n').forEach(line => {
    const [k, ...v] = line.split('=');
    const val = v.join('=').trim().replace(/"/g, '').replace(/'/g, '');
    if (k === 'VITE_SUPABASE_URL' || k === 'SUPABASE_URL') url = val;
    if (k === 'VITE_SUPABASE_ANON_KEY') key = val;
});

const reqUrl = new URL(url + '/rest/v1/rpc/exec_debug_sql');
const options = {
    hostname: reqUrl.hostname,
    port: reqUrl.port,
    path: reqUrl.pathname + reqUrl.search,
    method: 'POST',
    headers: {
        'apikey': key,
        'Authorization': 'Bearer ' + key,
        'Content-Type': 'application/json'
    }
};

const postData = JSON.stringify({
    q: `ALTER FUNCTION public.exec_debug_sql(text) SECURITY INVOKER;`
});

const req = https.request(options, (res) => {
    let body = '';
    res.on('data', d => body += d);
    res.on('end', () => {
        console.log('Response:', body);
    });
});

req.write(postData);
req.end();
