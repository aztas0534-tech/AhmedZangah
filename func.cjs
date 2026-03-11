const fs = require('fs');
let content = fs.readFileSync('formatted_db_functions.json', 'utf16le');
if (content.charCodeAt(0) === 0xFEFF) content = content.slice(1);
const o = JSON.parse(content);
const f = o.find(x => x.name === '_require_staff');
if (f) console.log(f.body);
else console.log('Not found');
