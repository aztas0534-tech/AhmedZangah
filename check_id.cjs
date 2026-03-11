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
  console.log('MenuItems:', await fetchJSON(`menu_items?id=eq.${id}&select=id,name`));
  console.log('Batches by ID:', await fetchJSON(`batches?id=eq.${id}&select=id,item_id,warehouse_id,status,quantity_received,quantity_consumed,quantity_transferred`));
}
run();
