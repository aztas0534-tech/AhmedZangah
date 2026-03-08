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
  const { data, error } = await supabase.rpc('query_executor_func', {
    p_query: `
      select trigger_name, action_statement
      from information_schema.triggers
      where event_object_table = 'order_item_cogs';
    `
  });
  
  if (error || !data) {
    console.log("Error querying triggers remotely. Checking local instead...");
    let schema = fs.readFileSync('tmp_local_schema.sql', 'utf8');
    let lines = schema.split('\n');
    let inTrigger = false;
    for (let line of lines) {
        if (line.toLowerCase().includes('create trigger') && line.toLowerCase().includes('order_item_cogs')) {
             console.log("Trigger found locally:", line.trim());
        }
    }
    return;
  }
  
  console.log("Triggers:", data);
}

check();
