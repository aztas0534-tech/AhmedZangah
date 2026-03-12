import * as crypto from 'crypto';
import * as fs from 'fs';

const url = 'https://pmhivhtaoydfolseelyc.supabase.co';
const jwtSecret = 'AhmadZangah1#123455'; 

function generateServiceRoleJwt() {
  const base64url = (str) => str.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  const header = base64url(Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64'));
  const payload = base64url(Buffer.from(JSON.stringify({ role: 'service_role', exp: Math.floor(Date.now() / 1000) + 3600 })).toString('base64'));
  const signature = base64url(crypto.createHmac('sha256', jwtSecret).update(header + '.' + payload).digest('base64'));
  return header + '.' + payload + '.' + signature;
}

const token = generateServiceRoleJwt();
const sql = fs.readFileSync('update_deduct_stock.sql', 'utf8');

async function run() {
  console.log('Sending exec_sql request with locally generated service_role JWT...');
  const res = await fetch(`${url}/rest/v1/rpc/exec_sql`, {
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
