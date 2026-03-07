import { getSupabaseClient } from './src/supabase';

async function run() {
  const supabase = getSupabaseClient();
  const { data, error } = await supabase.rpc('get_accounting_tree_v2');
  if (error) console.error(error);
  else console.log(JSON.stringify(data.filter((a: any) => a.code.startsWith('101') || a.code.startsWith('102') || a.code.startsWith('103')), null, 2));
}

run();
