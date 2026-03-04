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
  const r1 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT p.proname,
      CASE WHEN position('party_id' in p.prosrc) > 0 THEN 'YES' ELSE 'NO' END as party_id,
      CASE WHEN position('currency_code' in p.prosrc) > 0 THEN 'YES' ELSE 'NO' END as currency,
      CASE WHEN position('fx_rate' in p.prosrc) > 0 THEN 'YES' ELSE 'NO' END as fx_rate,
      CASE WHEN position('foreign_amount' in p.prosrc) > 0 THEN 'YES' ELSE 'NO' END as foreign_amt
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'void_journal_entry',
        'create_reversal_entry',
        'reverse_journal_entry',
        'void_delivered_order',
        'reverse_payment_journal'
      )
    ORDER BY p.proname
  ) t;`);
  console.log('FINAL VERIFICATION:');
  console.log(r1);
}

run();
