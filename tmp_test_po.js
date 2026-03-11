import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch { try { envLocal = fs.readFileSync('.env', 'utf8'); } catch { } }

let supabaseUrl = '';
let supabaseKey = '';

for (const line of envLocal.split('\n')) {
    if (line.startsWith('VITE_SUPABASE_URL=')) supabaseUrl = line.split('=')[1].trim();
    if (line.startsWith('SUPABASE_SERVICE_ROLE_KEY=')) supabaseKey = line.split('=')[1].trim();
    else if (!supabaseKey && line.startsWith('VITE_SUPABASE_ANON_KEY=')) supabaseKey = line.split('=')[1].trim();
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    const adminIdResult = await supabase.from('users').select('id').limit(1);
    const adminId = adminIdResult.data?.[0]?.id;

    const supplierResult = await supabase.from('suppliers').select('id').limit(1);
    const supplierId = supplierResult.data?.[0]?.id;

    const whResult = await supabase.from('warehouses').select('id').limit(1);
    const whId = whResult.data?.[0]?.id;

    if (!adminId || !supplierId || !whId) {
        console.log("Missing prerequisites", { adminId, supplierId, whId });
        return;
    }

    const { data, error } = await supabase
        .from('purchase_orders')
        .insert([{
            supplier_id: supplierId,
            purchase_date: new Date().toISOString().split('T')[0],
            currency: 'YER',
            total_amount: 100,
            items_count: 1,
            created_by: adminId,
            status: 'draft',
            warehouse_id: whId,
            payment_terms: 'cash',
            net_days: 0,
            due_date: new Date().toISOString().split('T')[0],
        }]);

    console.log("Order Insert Result:", error);
}
run();
