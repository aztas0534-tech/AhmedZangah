const https = require('https');
const reqOpts = {
  hostname: 'pmhivhtaoydfolseelyc.supabase.co',
  path: '/rest/v1/rpc/check_db_state',
  method: 'POST',
  headers: {
    'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Accept': 'application/json',
    'Content-Type': 'application/json'
  }
};

function fetchJSON(body) {
  return new Promise((resolve, reject) => {
    const req = https.request(reqOpts, (res) => {
      let data = ''; res.on('data', c => data+=c); res.on('end', () => resolve(JSON.parse(data)));
    });
    req.on('error', reject);
    req.write(JSON.stringify(body)); req.end();
  });
}

async function run() {
  const result1 = await fetchJSON({
    p_query: "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='inventory_movements'"
  });
  console.log('inventory_movements cols:', result1);

  const result2 = await fetchJSON({
    p_query: "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='orders'"
  });
  console.log('orders cols:', result2);
  
  const result3 = await fetchJSON({
    p_query: "SELECT tgname, pg_get_triggerdef(oid) as def FROM pg_trigger WHERE tgrelid = 'public.orders'::regclass"
  });
  console.log('orders triggers:', result3);
}
run();
