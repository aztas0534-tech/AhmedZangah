import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import { resolve } from 'path';

dotenv.config({ path: resolve('c:/nasrflash/AhmedZ/.env') });
dotenv.config({ path: resolve('c:/nasrflash/AhmedZ/.env.local') });

const url = process.env.VITE_SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.VITE_SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!url || !key) {
    console.error("Missing Supabase credentials");
    process.exit(1);
}

const supabase = createClient(url, key);

async function main() {
    const { data, error } = await supabase.from('payroll_employees').insert({
        full_name: 'Debug Test Employee',
        monthly_salary: 1000,
        currency: 'YER',
        is_active: true
    }).select();

    if (error) {
        console.error("EXPECTED ERROR:", JSON.stringify(error, null, 2));
    } else {
        console.log("SUCCESS:", data);
    }
}

main();
