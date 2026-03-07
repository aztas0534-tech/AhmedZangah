import * as fs from 'fs';
import { createClient } from '@supabase/supabase-js';

const envFile = fs.readFileSync('c:\\nasrflash\\AhmedZ\\.env.local', 'utf-8');
const env: Record<string, string> = {};
envFile.split(/\r?\n/).forEach(line => {
  const match = line.match(/^([^=]+)=(.*)$/);
  if (match) env[match[1].trim()] = match[2].trim();
});

const url = env['VITE_SUPABASE_URL'];
const key = env['VITE_SUPABASE_SERVICE_ROLE_KEY'] || env['VITE_SUPABASE_ANON_KEY'];
const supabase = createClient(url, key);

async function run() {
  const { data, error } = await supabase.rpc('exec_debug_sql', { 
    q: "select jsonb_agg(column_name) from information_schema.columns where table_name = 'chart_of_accounts'" 
  });
  console.log('Columns:', data);
  if (error) console.error(error);
}

run();
