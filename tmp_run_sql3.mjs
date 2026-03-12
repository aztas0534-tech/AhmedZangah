import * as fs from 'fs';

const url = 'https://sbp_7034822f291b12df0a1c95b1130f3a6fe5818dfd.supabase.co';
// The user gave the token: sbp_7034822f291b12df0a1c95b1130f3a6fe5818dfd
// Wait, based on the URL in error earlier, let me parse .env.production cleanly
const envVars = fs.readFileSync('.env.production', 'utf8');
const urlMatch = envVars.match(/VITE_SUPABASE_URL=(.*)/);
const keyMatch = envVars.match(/VITE_SUPABASE_ANON_KEY=(.*)/);
const realUrl = urlMatch ? urlMatch[1].trim() : '';
// The user provided 'sbp_7034822f291b12df0a1c95b1130f3a6fe5818dfd' as the token.
const token = 'sbp_7034822f291b12df0a1c95b1130f3a6fe5818dfd'; 

const sql = fs.readFileSync('update_deduct_stock.sql', 'utf8');

async function run() {
  console.log('Sending exec_sql request to ' + realUrl);
  const res = await fetch(`${realUrl}/rest/v1/rpc/exec_sql`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'ApiKey': token,
      'Authorization': `Bearer ${token}`
    },
    body: JSON.stringify({ query: sql })
  });

  const text = await res.text();
  console.log('Status:', res.status);
  console.log('Response:', text);
}

run();
