import fs from 'node:fs';
import readline from 'node:readline';

const filePath = process.argv[2] || 'supabase/.temp/remote_schema_migrations.sql';
const maxTail = Number(process.argv[3] || 30);

if (!fs.existsSync(filePath)) {
  console.error(`File not found: ${filePath}`);
  process.exit(1);
}

const input = fs.createReadStream(filePath, { encoding: 'utf8' });
const rl = readline.createInterface({ input, crlfDelay: Infinity });

let inCopy = false;
const rows = [];

for await (const line of rl) {
  if (!inCopy) {
    if (line.startsWith('COPY "supabase_migrations"."schema_migrations"')) {
      inCopy = true;
    }
    continue;
  }

  if (line === '\\.') break;
  if (!line.trim()) continue;

  const parts = line.split('\t');
  if (parts.length >= 3) {
    rows.push({ version: parts[0], name: parts[2] });
  }
}

rows.sort((a, b) => String(a.version).localeCompare(String(b.version)));

console.log(`count\t${rows.length}`);
console.log('tail');
for (const r of rows.slice(-maxTail)) {
  console.log(`${r.version}\t${r.name}`);
}

