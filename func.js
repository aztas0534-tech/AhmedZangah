const fs = require('fs');
const o = JSON.parse(fs.readFileSync('formatted_db_functions.json', 'utf8').replace(/^\uFEFF/, ''));
const f = o.find(x => x.name === '_require_staff');
if (f) console.log(f.body);
else console.log('Not found');
