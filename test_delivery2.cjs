const fs = require('fs');
let key = '';
const lines = fs.readFileSync('tmp_query.js', 'utf8').split('\n');
for (let l of lines) {
  if (l.includes('SUPABASE_SERVICE_ROLE_KEY=')) {
    key = l.split('=')[1].trim().replace(/['";]/g, '');
    break;
  }
}
console.log('KEY:', key.substring(0, 5) + '...' + key.substring(key.length - 5));

const https = require('https');
const reqOpts = {
  hostname: 'pmhivhtaoydfolseelyc.supabase.co',
  path: '/rest/v1/rpc/confirm_order_delivery_with_credit',
  method: 'POST',
  headers: {
    'apikey': key,
    'Authorization': 'Bearer ' + key,
    'Accept': 'application/json',
    'Content-Type': 'application/json'
  }
};
function fetchJSON(body) {
  return new Promise((resolve) => {
    const req = https.request(reqOpts, (res) => {
      let data = ''; res.on('data', c => data+=c); res.on('end', () => resolve(JSON.parse(data || '{}')));
    });
    req.write(JSON.stringify(body));
    req.end();
  });
}
async function run() {
  const result = await fetchJSON({ p_payload: { p_order_id: '11111111-1111-1111-1111-111111111111', p_items: [], p_warehouse_id: '11111111-1111-1111-1111-111111111111' } });
  console.log(JSON.stringify(result, null, 2));
}
run();
