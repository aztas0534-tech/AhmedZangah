import { createClient } from '@supabase/supabase-js';
const supabaseUrl = 'https://pmhivhtaoydfolseelyc.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec';
const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
  // Find all payments where amount ≈ base_amount but currency != SAR
  const { data: payments, error } = await supabase
    .from('payments')
    .select('id, amount, base_amount, currency, fx_rate, reference_table, reference_id, direction, method')
    .not('currency', 'is', null)
    .neq('currency', 'SAR')
    .order('created_at', { ascending: false });

  if (error) { console.error('Error:', error); return; }

  console.log(`Total non-SAR payments: ${payments?.length || 0}\n`);

  for (const p of (payments || [])) {
    const ratio = Math.abs(p.amount / (p.base_amount || 1));
    const isSuspect = Math.abs(p.amount - (p.base_amount || 0)) < 1.0;
    console.log(`Payment ${p.id.slice(-8)}: currency=${p.currency} amount=${p.amount} base=${p.base_amount} fx=${p.fx_rate} ratio=${ratio.toFixed(4)} SUSPECT=${isSuspect} ref=${p.reference_table}/${p.reference_id?.slice(-8)}`);
  }
}
run();
