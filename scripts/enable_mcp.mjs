import { createClient } from '@supabase/supabase-js';
import * as dotenv from 'dotenv';
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';

const envPath = join(process.cwd(), '.env');
const envLocalPath = join(process.cwd(), '.env.local');
if (existsSync(envPath)) dotenv.config({ path: envPath });
if (existsSync(envLocalPath)) dotenv.config({ path: envLocalPath });

const supabaseUrl = process.env.VITE_SUPABASE_URL || process.env.SUPABASE_URL;
const supabaseKey = process.env.VITE_SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseKey) {
  console.error("Missing SUPABASE URL or KEY");
  process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function enableMCP() {
  console.log("Enabling Multi-Currency Pricing...");
  
  // 1. Fetch current settings
  const { data: currentSettings, error: fetchErr } = await supabase
    .from('app_settings')
    .select('id, data')
    .in('id', ['singleton', 'app'])
    .order('id', { ascending: false })
    .limit(1);
    
  if (fetchErr) {
    console.error("Error fetching settings:", fetchErr);
    return;
  }
  
  if (!currentSettings || currentSettings.length === 0) {
    console.error("No app_settings row found.");
    return;
  }
  
  const row = currentSettings[0];
  const data = row.data || {};
  data.ENABLE_MULTI_CURRENCY_PRICING = true;
  
  // 2. Update settings
  const { error: updateErr } = await supabase
    .from('app_settings')
    .update({ data })
    .eq('id', row.id);
    
  if (updateErr) {
    console.error("Error updating settings:", updateErr);
  } else {
    console.log("Successfully enabled ENABLE_MULTI_CURRENCY_PRICING in app_settings.");
  }
}

enableMCP().catch(console.error);
