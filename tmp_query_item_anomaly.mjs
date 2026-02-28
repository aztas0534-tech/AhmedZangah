import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envProd = '';
try { envProd = fs.readFileSync('.env.production', 'utf8'); } catch { }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envProd.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const sql = `
    with item as (
      select id from public.menu_items where name->>'ar' like '%ماء طيبة صغير%' limit 1
    )
    select jsonb_build_object(
      'item_id', i.id,
      'batches', (select jsonb_agg(b) from (select id, quantity_received, quantity_consumed, status, qc_status, unit_cost from public.batches where item_id = i.id::text) b),
      'movements', (select jsonb_agg(m) from (select id, batch_id, movement_type, quantity, unit_cost, reference_table, occurred_at from public.inventory_movements where item_id = i.id::text order by occurred_at asc) m),
      'batch_balances', (select jsonb_agg(bb) from (select batch_id, quantity from public.batch_balances where item_id = i.id::text) bb),
      'returns', (select jsonb_agg(r) from (select pri.id, pri.purchase_order_id, pri.quantity, pri.unit_cost from public.purchase_return_items pri where pri.item_id = i.id::text) r),
      'sm', (select jsonb_build_object('available', sm.available_quantity, 'avg_cost', sm.avg_cost) from public.stock_management sm where item_id = i.id::text limit 1)
    ) as result
    from item i;
  `;

    const { data, error } = await supabase.rpc('execute_sql', { sql });
    if (error) {
        console.error("SQL Error:", error);
    } else {
        console.dir(data, { depth: null });
    }
}
run();
