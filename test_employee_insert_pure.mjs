import https from 'https';
import fs from 'fs';
import path from 'path';

let envStr = '';
try {
  const envPath = path.resolve('c:/nasrflash/AhmedZ/.env.local');
  envStr = fs.readFileSync(envPath, 'utf8');
} catch (e) { process.exit(1); }

let url = '', key = '';
envStr.split('\n').forEach(line => {
  const [k, ...v] = line.split('=');
  const val = v.join('=').trim().replace(/"/g, '').replace(/'/g, '');
  if (k === 'VITE_SUPABASE_URL') url = val;
  if (k === 'VITE_SUPABASE_ANON_KEY') key = val;
});

const rpc = (q) => new Promise(resolve => {
  const reqUrl = new URL(url + '/rest/v1/rpc/exec_debug_sql');
  const options = {
    hostname: reqUrl.hostname, path: reqUrl.pathname,
    method: 'POST',
    headers: { 'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json' }
  };
  const req = https.request(options, res => {
    let b = ''; res.on('data', d => b += d); res.on('end', () => resolve(b));
  });
  req.write(JSON.stringify({ q })); req.end();
});

async function run() {
  // 1. payroll_attendance structure
  const r1 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT column_name, data_type 
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'payroll_attendance'
    ORDER BY ordinal_position
  ) t;`);
  console.log('=== payroll_attendance ===');
  console.log(r1);

  // 2. payroll_employees structure
  const r2 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT column_name, data_type 
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'payroll_employees'
    ORDER BY ordinal_position
  ) t;`);
  console.log('=== payroll_employees ===');
  console.log(r2);

  // 3. Count employees
  const r3 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT count(*) as total,
      count(*) FILTER (WHERE status = 'active') as active
    FROM payroll_employees
  ) t;`);
  console.log('=== employee count ===');
  console.log(r3);

  // 4. Sample attendance data
  const r4 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT * FROM payroll_attendance
    ORDER BY work_date DESC
    LIMIT 5
  ) t;`);
  console.log('=== recent attendance ===');
  console.log(r4);

  // 5. Check auth users table
  const r5 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT column_name, data_type 
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'admin_users'
    ORDER BY ordinal_position
  ) t;`);
  console.log('=== admin_users ===');
  console.log(r5);

  // 6. Check roles/permissions
  const r6 = await rpc(`SELECT jsonb_agg(row_to_json(t)) FROM (
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND (table_name LIKE '%role%' OR table_name LIKE '%perm%' OR table_name LIKE '%admin%')
    ORDER BY table_name
  ) t;`);
  console.log('=== role/permission tables ===');
  console.log(r6);
}

run();
