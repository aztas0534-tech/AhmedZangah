import https from 'https';
import fs from 'fs';
import path from 'path';

let envStr = '';
try {
    const envPath = path.resolve('c:/nasrflash/AhmedZ/.env.local');
    envStr = fs.readFileSync(envPath, 'utf8');
} catch (e) {
    try {
        const envPath = path.resolve('c:/nasrflash/AhmedZ/.env');
        envStr = fs.readFileSync(envPath, 'utf8');
    } catch (e2) {
        console.error("No env file");
        process.exit(1);
    }
}

let url = '';
let key = '';

envStr.split('\n').forEach(line => {
    const [k, ...v] = line.split('=');
    if (k === 'VITE_SUPABASE_URL' || k === 'NEXT_PUBLIC_SUPABASE_URL') url = v.join('=').trim().replace(/"/g, '').replace(/'/g, '');
    if (k === 'VITE_SUPABASE_ANON_KEY' || k === 'NEXT_PUBLIC_SUPABASE_ANON_KEY') key = v.join('=').trim().replace(/"/g, '').replace(/'/g, '');
});

if (!url || !key) {
    console.log("Missing URL/KEY", url, key);
    process.exit(1);
}

const postData = JSON.stringify({
    full_name: 'Debug Test Employee ' + Date.now(),
    monthly_salary: 1000,
    currency: 'YER',
    is_active: true,
    credit_limit_multiplier: 2,
    auto_deduct_ar: true
});

const reqUrl = new URL(url + '/rest/v1/payroll_employees');
const options = {
    hostname: reqUrl.hostname,
    port: reqUrl.port,
    path: reqUrl.pathname + reqUrl.search,
    method: 'POST',
    headers: {
        'apikey': key,
        'Authorization': 'Bearer ' + key,
        'Content-Type': 'application/json',
        'Prefer': 'return=representation'
    }
};

const req = https.request(options, (res) => {
    let body = '';
    res.on('data', d => body += d);
    res.on('end', () => {
        console.log('Status code:', res.statusCode);
        console.log('Response body:', body);
    });
});

req.on('error', e => console.error(e));
req.write(postData);
req.end();
