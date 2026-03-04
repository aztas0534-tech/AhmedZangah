import { Client } from 'pg';
import fs from 'fs';
import path from 'path';

let envStr = '';
try {
    const envPath = path.resolve('c:/nasrflash/AhmedZ/.env.production');
    envStr = fs.readFileSync(envPath, 'utf8');
} catch (e) {
    try {
        const envPath = path.resolve('c:/nasrflash/AhmedZ/.env');
        envStr = fs.readFileSync(envPath, 'utf8');
    } catch (e2) {
        console.error("No env file");
        process.exit(1);
    }
}

let connStr = '';
envStr.split('\n').forEach(line => {
    const [k, ...v] = line.split('=');
    const val = v.join('=').trim().replace(/"/g, '').replace(/'/g, '');
    if (k === 'DATABASE_URL' || k === 'SUPABASE_DB_URL') connStr = val;
});

if (!connStr) {
    console.log("No db connection string found");
    process.exit(0);
}

const client = new Client({ connectionString: connStr });

async function run() {
    await client.connect();
    let adminId;
    const res = await client.query("SELECT auth_user_id FROM public.admin_users WHERE is_active = true LIMIT 1;");
    if (res.rows.length) adminId = res.rows[0].auth_user_id;

    if (adminId) {
        await client.query(`SET ROLE authenticated;`);
        await client.query(`SET request.jwt.claim.sub = '${adminId}';`);
        await client.query(`SET request.jwt.claim.role = 'authenticated';`);

        try {
            await client.query(`SELECT id FROM public.payroll_employees LIMIT 1;`);
            console.log('payroll_employees OK');
        } catch (e) { console.error('payroll_employees ERROR', e.message); }

        try {
            await client.query(`SELECT id FROM public.payroll_runs LIMIT 1;`);
            console.log('payroll_runs OK');
        } catch (e) { console.error('payroll_runs ERROR', e.message); }

        try {
            await client.query(`SELECT id FROM public.cost_centers LIMIT 1;`);
            console.log('cost_centers OK');
        } catch (e) { console.error('cost_centers ERROR', e.message); }

        try {
            await client.query(`SELECT id FROM public.payroll_settings LIMIT 1;`);
            console.log('payroll_settings OK');
        } catch (e) { console.error('payroll_settings ERROR', e.message); }

    }
    await client.end();
}

run();
