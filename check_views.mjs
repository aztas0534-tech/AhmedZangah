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
  const { data: views, error } = await supabase.rpc('query_executor_func', {
    p_query: `
      select table_schema, table_name 
      from information_schema.views 
      where table_schema = 'public';
    `
  });
  
  if (error || !views) {
    console.log("Error querying views", error);
    return;
  }
  
  console.log("Public Views:");
  console.log(views);
  
}

check();
