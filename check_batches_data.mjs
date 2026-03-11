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
  const { data: b, error: e1 } = await supabase.from('batches').select('id, data').limit(1);
  console.log("Batches data:", b ? "OK" : "ERROR", e1?.message);

  const { data: i, error: e2 } = await supabase.from('inventory_movements').select('id, data').limit(1);
  console.log("Movements data:", i ? "OK" : "ERROR", e2?.message);

  const { data: s, error: e3 } = await supabase.from('stock_management').select('item_id, data').limit(1);
  console.log("Stock data:", s ? "OK" : "ERROR", e3?.message);
}

check();
