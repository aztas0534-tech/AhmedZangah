import { createClient } from '@supabase/supabase-js';

const url = (process.env.AZTA_SUPABASE_URL || '').trim();
const anon = (process.env.AZTA_SUPABASE_ANON_KEY || '').trim();
if (!url || !anon) {
  console.error('Missing AZTA_SUPABASE_URL / AZTA_SUPABASE_ANON_KEY');
  process.exit(1);
}

const email = process.env.AZTA_OWNER_EMAIL || 'owner@azta.com';
const password = process.env.AZTA_OWNER_PASSWORD || 'Owner@123';
const fullName = process.env.AZTA_OWNER_NAME || 'Owner';
const role = process.env.AZTA_OWNER_ROLE || 'owner';

const supabase = createClient(url, anon);

(async () => {
  try {
    const res = await supabase.functions.invoke('create-admin-user', {
      body: { email, password, fullName, role },
    });
    if (res?.error) {
      console.error('invoke error:', res.error.message || res.error);
      process.exit(1);
    }
    console.log('OK ensure-owner', email);
    process.exit(0);
  } catch (e) {
    console.error(String(e?.message || e));
    process.exit(1);
  }
})();
