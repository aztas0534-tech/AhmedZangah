const https = require('https');
const fs = require('fs');

const reqOpts = {
  hostname: 'pmhivhtaoydfolseelyc.supabase.co',
  path: '/rest/v1/rpc/get_schema_info',
  method: 'POST',
  headers: {
    'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec',
    'Accept': 'application/json',
    'Content-Type': 'application/json'
  }
};
function fetchJSON() {
  return new Promise((resolve) => {
    const req = https.request(reqOpts, (res) => {
      let data = ''; res.on('data', c => data+=c); res.on('end', () => resolve(JSON.parse(data)));
    });
    req.end();
  });
}
async function run() {
  const result = await fetchJSON();
  let text = '';
  for (const f of result.funcs) {
    text += `\n=========================================\n`;
    text += `FUNCTION: ${f.name}\n`;
    text += `=========================================\n`;
    text += f.src + '\n';
  }
  fs.writeFileSync('formatted_funcs.txt', text);
  console.log('Saved to formatted_funcs.txt');
}
run();
