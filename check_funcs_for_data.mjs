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
  const { data: noDataCols } = await supabase.rpc('query_executor_func', {
    p_query: `
      select string_agg(t.table_name, ', ') as tbls
      from information_schema.tables t
      where t.table_schema = 'public'
        and t.table_type = 'BASE TABLE'
        and not exists (
          select 1 from information_schema.columns c
          where c.table_schema = 'public'
            and c.table_name = t.table_name
            and c.column_name = 'data'
        );
    `
  });
  
  if (!noDataCols || noDataCols.length === 0) {
    console.log("Could not query or no tables found.");
    return;
  }
  const tbls = noDataCols[0].tbls.split(', ');
  console.log("Tables without data:", tbls.length);

  const { data: funcs } = await supabase.rpc('query_executor_func', {
    p_query: `
      select p.proname, p.prosrc
      from pg_proc p
      join pg_namespace n on p.pronamespace = n.oid
      where n.nspname = 'public'
    `
  });

  if (!funcs) {
    console.log("Could not query functions.");
    return;
  }

  for (const f of funcs) {
    const src = (f.prosrc || '').toLowerCase();
    for (const t of tbls) {
      if (src.includes(t)) {
        // regex to check update ... data
        // naive check first
        if (src.includes('update ') && src.includes('data =')) {
          // let's print potential suspects
          let lines = src.split('\n');
          for (const l of lines) {
             if (l.includes('update ') && l.includes(t) && l.includes('data')) {
               console.log("SUSPECT FORMATTING in " + f.proname + " on table " + t + " => " + l.trim());
             }
          }
        }
      }
    }
  }
  console.log("Scan complete.");
}

check();
