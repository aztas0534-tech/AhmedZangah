import { createClient } from '@supabase/supabase-js';

const supabaseUrl = 'https://pmhivhtaoydfolseelyc.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec';

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
  await new Promise(r => setTimeout(r, 3000));

  // Test confirm_order_delivery with dummy UUID — should get "order not found" NOT "column data"
  console.log('=== Testing confirm_order_delivery (4-arg) ===');
  const { data: d1, error: e1 } = await supabase.rpc('confirm_order_delivery', {
    p_order_id: '00000000-0000-0000-0000-000000000001',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000002'
  });
  console.log('Error:', JSON.stringify(e1, null, 2));
  console.log('Data:', d1);

  console.log('\n=== Testing confirm_order_delivery_with_credit (4-arg) ===');
  const { data: d2, error: e2 } = await supabase.rpc('confirm_order_delivery_with_credit', {
    p_order_id: '00000000-0000-0000-0000-000000000001',
    p_items: [],
    p_updated_data: {},
    p_warehouse_id: '00000000-0000-0000-0000-000000000002'
  });
  console.log('Error:', JSON.stringify(e2, null, 2));
  console.log('Data:', d2);
}

run();
