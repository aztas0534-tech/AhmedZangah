import { createClient } from '@supabase/supabase-js';
const supabaseUrl = 'https://pmhivhtaoydfolseelyc.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec';
const supabase = createClient(supabaseUrl, supabaseKey);

async function check() {
  console.log('--- Orders ---');
  const { data: orders } = await supabase
    .from('orders')
    .select('id, invoice_number, status, total, currency')
    .in('invoice_number', ['INV-001220', 'INV-001272']); // The two deliveries in the image
  console.log(orders);

  console.log('\n--- Payments linked to orders ---');
  if (orders && orders.length > 0) {
    const orderIds = orders.map(o => o.id);
    const { data: payments } = await supabase
      .from('payments')
      .select('id, amount, base_amount, currency, reference_id')
      .in('reference_id', orderIds.map(id => String(id)));
    console.log(payments);
  }
}
check();
