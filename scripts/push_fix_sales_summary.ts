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
  console.log('🔧 Pushing fixed get_sales_report_summary...');
  let sql = fs.readFileSync('c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260309231000_fix_sales_summary_expenses_column.sql', 'utf-8');
  sql = sql.replace(/select pg_sleep\([^)]+\);/gi, '');
  
  const result = await supabase.rpc('exec_debug_sql', { q: sql });
  if (result.error) {
    console.error('Supabase error:', result.error);
  } else if (result.data && result.data.error) {
    console.error('SQL error:', result.data);
    
    // If the full SQL fails, try splitting into function + grants
    console.log('\n📦 Trying split approach...');
    const fnMatch = sql.match(/(create or replace function[\s\S]*?\$fn\$;)/i);
    if (fnMatch) {
      console.log('  Pushing function only...');
      const r1 = await supabase.rpc('exec_debug_sql', { q: fnMatch[1] });
      console.log('  Function result:', r1.data);
    }
    
    // Try grants
    const grantSql = `
      revoke all on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from public;
      grant execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) to anon, authenticated;
    `;
    console.log('  Pushing grants...');
    const r2 = await supabase.rpc('exec_debug_sql', { q: grantSql });
    console.log('  Grants result:', r2.data);
    
    console.log('  Schema reload...');
    const r3 = await supabase.rpc('exec_debug_sql', { q: "notify pgrst, 'reload schema';" });
    console.log('  Reload result:', r3.data);
  } else {
    console.log('✅ Push OK');
  }

  // Test the function
  console.log('\n🧪 Testing function...');
  const test = await supabase.rpc('exec_debug_sql', {
    q: "select get_sales_report_summary('2026-01-01'::timestamptz, '2026-12-31'::timestamptz, null::uuid, false)"
  });
  console.log('Result:', JSON.stringify(test.data, null, 2));
}

run();
