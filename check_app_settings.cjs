const https = require('https');

const reqOpts = {
  hostname: 'pmhivhtaoydfolseelyc.supabase.co',
  path: '/rest/v1/app_settings?select=data&limit=1',
  method: 'GET',
  headers: {
    'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Accept': 'application/json'
  }
};
function fetchJSON() {
  return new Promise((resolve) => {
    https.get(reqOpts, (res) => {
      let data = ''; res.on('data', c => data+=c); res.on('end', () => resolve(JSON.parse(data || '{}')));
    });
  });
}
async function run() {
  const result = await fetchJSON();
  console.log('Result:', JSON.stringify(result, null, 2));
}
run();
