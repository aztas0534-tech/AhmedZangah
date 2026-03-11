import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch {}
try { envLocal += fs.readFileSync('.env.production', 'utf8'); } catch {}

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
    else if (!supabaseKey && line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function check() {
  console.log("Testing SELECT against a missing column:");
  const res1 = await supabase.from('warehouses').select('data').limit(1);
  console.log(JSON.stringify(res1.error));
  
  console.log("Testing UPDATE against a missing column:");
  const res2 = await supabase.from('warehouses').update({ data: '{}' }).eq('id', '00000000-0000-0000-0000-000000000000');
  console.log(JSON.stringify(res2.error));
}

check();
