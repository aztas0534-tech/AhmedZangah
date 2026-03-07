import { getSupabaseClient } from './src/supabase';

async function run() {
  const supabase = getSupabaseClient();
  const { data, error } = await supabase.from('chart_of_accounts').select('id, code, name, parent_id, account_type').like('code', '10%').order('code');
  if (error) console.error(error);
  else console.log(JSON.stringify(data, null, 2));
}

run();
