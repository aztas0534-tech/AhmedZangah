import fs from 'fs';

// Parse the migration status file
const statusFile = fs.readFileSync('migration_status.txt', 'utf8');
const lines = statusFile.split('\n');

const remoteTimestamps = new Set();
for (const line of lines) {
  const match = line.trim().match(/^\s*(\d{14})\s*\|/);
  if (match) {
    remoteTimestamps.add(match[1]);
  }
}

// Parse the local migration files
const migrationDir = 'supabase/migrations';
const localFiles = fs.readdirSync(migrationDir);
const localTimestamps = new Map();
for (const file of localFiles) {
  if (!file.endsWith('.sql')) continue;
  const match = file.match(/^(\d{14})/);
  if (match) {
    localTimestamps.set(match[1], file);
  }
}

console.log(`Remote migrations applied: ${remoteTimestamps.size}`);
console.log(`Local migration files: ${localTimestamps.size}`);
console.log('');

// Find local files NOT on remote
const missingOnRemote = [];
for (const [ts, file] of localTimestamps) {
  if (!remoteTimestamps.has(ts)) {
    missingOnRemote.push({ timestamp: ts, file });
  }
}

// Find remote entries NOT in local
const missingLocally = [];
for (const ts of remoteTimestamps) {
  if (!localTimestamps.has(ts)) {
    missingLocally.push(ts);
  }
}

if (missingOnRemote.length > 0) {
  console.log('=== LOCAL MIGRATIONS NOT APPLIED ON PRODUCTION ===');
  for (const m of missingOnRemote.sort((a,b) => a.timestamp.localeCompare(b.timestamp))) {
    console.log(`  MISSING: ${m.file}`);
  }
} else {
  console.log('All local migrations are applied on production.');
}

console.log('');

if (missingLocally.length > 0) {
  console.log('=== REMOTE MIGRATIONS NOT IN LOCAL FILES ===');
  for (const ts of missingLocally.sort()) {
    console.log(`  EXTRA ON REMOTE: ${ts}`);
  }
} else {
  console.log('All remote migrations have corresponding local files.');
}
