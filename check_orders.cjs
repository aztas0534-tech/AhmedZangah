const https = require('https');

const id = 'efa91c13-9cb2-4fb1-b3f0-4f711c22e59a';

const reqOpts = (path) => ({
  hostname: 'pmhivhtaoydfolseelyc.supabase.co',
  path: `/rest/v1/${path}`,
  method: 'GET',
  headers: {
    'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Accept': 'application/json'
  }
});

function fetchJSON(path) {
  return new Promise((resolve, reject) => {
    https.get(reqOpts(path), (res) => {
      let data = '';
      res.on('data', c => data+=c);
      res.on('end', () => resolve(JSON.parse(data)));
    }).on('error', reject);
  });
}

async function run() {
  // Try to find the order containing this ID in data->items
  const orders = await fetchJSON(`orders?select=id,data`);
  const matching = (orders || []).filter(o => JSON.stringify(o.data || {}).includes(id));
  console.log('Matching orders:', matching.length);
  if (matching.length > 0) {
     const order = matching[0];
     const item = (order.data?.items || []).find(i => JSON.stringify(i).includes(id));
     console.log('Matching item:', JSON.stringify(item, null, 2));
  }
}
run();
