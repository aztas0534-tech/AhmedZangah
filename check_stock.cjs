const https = require('https');

const url = 'https://pmhivhtaoydfolseelyc.supabase.co/rest/v1/rpc/check_db_state'; // Just random, let's use actual table queries
const itemId = 'efa91c13-9cb2-4fb1-b3f0-4f711c22e59a';

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
  const stock = await fetchJSON(`stock_management?item_id=eq.${itemId}&select=*`);
  console.log('Stock Management:', stock);
  const batches = await fetchJSON(`batches?item_id=eq.${itemId}&select=id,status,quantity_received,quantity_consumed,quantity_transferred,warehouse_id`);
  console.log('Batches:', batches);
}
run();
