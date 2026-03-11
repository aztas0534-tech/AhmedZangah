import { createClient } from '@supabase/supabase-js';
import * as fs from 'fs';
import * as path from 'path';

const envContent = fs.readFileSync(path.resolve(process.cwd(), '.env.local'), 'utf-8');
let supabaseUrl = '';
let supabaseKey = '';
for (const line of envContent.split('\n')) {
  if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
  if (line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function check() {
  console.log('Fetching recent orders...');
  const { data: o2, error: e2 } = await supabase.from('orders').select('*').order('created_at', { ascending: false }).limit(100);
  if (e2) {
    console.log('Error', e2)
    return;
  }
  
  const targetId = '6ca3c1';
  const found = o2.find(o => o.id.replace(/-/g, '').toLowerCase().includes(targetId) || o.id.toLowerCase().startsWith(targetId));
  
  if (!found) {
      console.log('Order not found even in last 100 orders.');
      console.log('Here are some recent IDs:', o2.slice(0, 5).map(x => x.id + ' | ' + x.data?.invoiceNumber));
      return;
  }
  
  const o = found;
  console.log('Order Found! ID:', o.id, o.status, o.total, o.currency);
  console.log('InvoiceNumber:', o.data?.invoiceNumber);

  if (o.data?.partyId) {
    console.log('Fetching party...');
    const { data: party, error: partyErr } = await supabase
      .from('financial_parties')
      .select('*, party_credit_limits(*)')
      .eq('id', o.data.partyId)
      .single();
      
    if (partyErr) {
      console.error('Party fetch error:', partyErr.message);
    } else {
      console.log('Party:', party.name);
      console.log('Limits:', party.party_credit_limits);
    }

    const { data: yerBalance } = await supabase.rpc('compute_party_ar_balance_by_currency', {
      p_party_id: o.data.partyId,
      p_currency_code: 'YER'
    });
    console.log('Current YER Balance for Party:', yerBalance);

    const { data: sarBalance } = await supabase.rpc('compute_party_ar_balance_by_currency', {
      p_party_id: o.data.partyId,
      p_currency_code: 'SAR'
    });
    console.log('Current SAR Balance for Party:', sarBalance);
  } else {
      console.log('No party ID on order data:', o.data);
  }
}

check();
