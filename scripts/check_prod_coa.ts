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
  const { data, error } = await supabase.from('chart_of_accounts').select('id, code, name').in('code', ['1020', '1030', '1030-001-SAR']);
  console.log('Exists:', data);
  if (error) console.error(error);
}

run();
