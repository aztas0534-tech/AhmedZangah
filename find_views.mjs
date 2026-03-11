import fs from 'fs';

let schema = fs.readFileSync('tmp_local_schema.sql', 'utf8');
let lines = schema.split('\n');

let views = [];
for (let i = 0; i < lines.length; i++) {
  if (lines[i].toLowerCase().includes('create view ') || lines[i].toLowerCase().includes('create or replace view ')) {
     views.push(lines[i].trim());
  }
}

console.log('Found views:', views);
