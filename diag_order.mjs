import { createClient } from '@supabase/supabase-js';
const supabaseUrl = 'https://pmhivhtaoydfolseelyc.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec';
const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
  // Check journal entries for the cancelled order #86A00D  
  const { data: cancelledEntries } = await supabase
    .from('journal_entries')
    .select('id, source_table, source_id, source_event, entry_date, memo, status')
    .or('source_id.ilike.%86a00d%,source_id.ilike.%86A00D%');
  
  console.log('Journal entries for cancelled order #86A00D:', JSON.stringify(cancelledEntries, null, 2));

  // Check journal entries for the delivered order #479F27
  const { data: deliveredEntries } = await supabase
    .from('journal_entries')
    .select('id, source_table, source_id, source_event, entry_date, memo, status')
    .or('source_id.ilike.%479f27%,source_id.ilike.%479F27%');
  
  console.log('Journal entries for delivered order #479F27:', JSON.stringify(deliveredEntries, null, 2));

  // Check payment A4D95F75
  const { data: paymentEntries } = await supabase
    .from('journal_entries')
    .select('id, source_table, source_id, source_event, entry_date, memo, status')
    .or('source_id.ilike.%a4d95f75%,source_id.ilike.%A4D95F75%');
  
  console.log('Journal entries for payment A4D95F75:', JSON.stringify(paymentEntries, null, 2));

  // Look for ALL journal entries with source_event containing 'reversal', 'void', or 'cancel'
  const { data: reversals } = await supabase
    .from('journal_entries')
    .select('id, source_table, source_id, source_event, entry_date, memo, status')
    .in('source_event', ['reversal', 'void', 'reversed', 'cancelled']);
  
  console.log('All reversal/void entries:', JSON.stringify(reversals, null, 2));

  // Check all orders for the customer
  const { data: orders } = await supabase
    .from('orders')
    .select('id, status, total, currency, fx_rate, invoice_number, data')
    .or('id.ilike.%86a00d%,id.ilike.%479f27%,id.ilike.%5ddd19%');
  
  console.log('Orders:', orders?.map(o => ({
    id: o.id?.slice(-8),
    status: o.status,
    total: o.total,
    currency: o.currency,
    invoice: o.invoice_number || o.data?.invoiceNumber
  })));
}
run();
