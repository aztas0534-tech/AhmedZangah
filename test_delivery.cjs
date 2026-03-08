const https = require('https');

const reqOpts = {
  hostname: 'pmhivhtaoydfolseelyc.supabase.co',
  path: '/rest/v1/rpc/confirm_order_delivery_with_credit',
  method: 'POST',
  headers: {
    'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
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
