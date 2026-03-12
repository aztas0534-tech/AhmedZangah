import { createClient } from '@supabase/supabase-js';
import * as fs from 'fs';
import * as dotenv from 'dotenv';
dotenv.config({ path: '.env.production' });

const supabaseUrl = process.env.VITE_SUPABASE_URL;
const supabaseKey = 'sbp_7034822f291b12df0a1c95b1130f3a6fe5818dfd'; // admin key provided by user

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
  const sql = fs.readFileSync('update_deduct_stock.sql', 'utf8');
  
  console.log('Attempting to execute SQL via exec_sql RPC...');
  const { data, error } = await supabase.rpc('exec_sql', { query: sql });
  
  if (error) {
    console.error('Error executing SQL via RPC:', error);
    // If exec_sql doesn't exist, we might be stuck without npx supabase or psql.
  } else {
    console.log('Success:', data);
  }
}

run();
