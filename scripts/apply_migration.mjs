
import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';

// Hardcoded credentials
const SUPABASE_URL = 'http://127.0.0.1:54321';
const SUPABASE_KEY = 'sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz';

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function applyMigration() {
    // UPDATED to point to the new fix
    const migrationPath = path.resolve('d:\\AhmedZ\\supabase\\migrations\\20260216235000_fix_post_movement_idempotency.sql');
    console.log(`Applying migration: ${migrationPath}`);

    try {
        const sql = fs.readFileSync(migrationPath, 'utf8');

        // Try exec_sql RPC
        const { error } = await supabase.rpc('exec_sql', { sql });

        if (error) {
            console.error('RPC exec_sql failed:', error.message);
            // Fallback: This user environment seems to lack direct SQL access tools that work reliably
            // So we rely on the USER to apply it if RPC fails. 
            // BUT, since "node" works, we might have access to "pg" driver or similar? 
            // The user has a bunch of scripts, maybe one uses 'pg'?
            // Checked package.json -> dependencies? No view of package.json.
            // But we will hope 'exec_sql' exists (it usually does in these setups).
            console.log('--- PLEASE APPLY MANUALLY ---');
        } else {
            console.log('Migration applied successfully via exec_sql!');
        }

    } catch (err) {
        console.error('Error reading/applying migration:', err);
    }
}

applyMigration();
