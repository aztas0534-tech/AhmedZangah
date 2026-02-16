
import { spawn } from 'node:child_process';
import fs from 'fs';
import path from 'path';

const runCapture = (label, cmd, args, opts = {}) => new Promise((resolve) => {
    // shell: true is needed for some windows commands but we try to avoid it for docker direct calls if possible
    // However, docker detection usually needs shell on windows for simple command parsing if not careful.
    // We will use shell: true for detection but shell: false for the main execution if possible, or careful args.
    const child = spawn(cmd, args, { shell: true, ...opts });
    let stdout = '';
    let stderr = '';
    child.stdout?.on('data', (d) => { stdout += String(d); });
    child.stderr?.on('data', (d) => { stderr += String(d); });
    child.on('exit', (code, signal) => {
        if (signal) return resolve({ code: 1, stdout, stderr: `${stderr}\n[${label}] exited with signal ${signal}`.trim() });
        resolve({ code: code ?? 0, stdout, stderr });
    });
});

async function main() {
    console.log('🔍 Finding Supabase DB container...');
    const ps = await runCapture('docker:ps', 'docker', ['ps', '--format', '{{.Names}}']);
    const dbContainer = String(ps.stdout || '')
        .split(/\r?\n/g)
        .map(s => s.trim())
        .filter(Boolean)
        .find(n => n.startsWith('supabase_db_'));

    if (!dbContainer) {
        console.error('❌ Could not find supabase_db container. Is it running?');
        process.exit(1);
    }
    console.log(`✅ Found container: ${dbContainer}`);

    const sqlPath = path.resolve('./scripts/force_delete_owner.sql');
    console.log(`📂 Reading SQL from: ${sqlPath}`);
    const sql = fs.readFileSync(sqlPath, 'utf8');

    console.log('🚀 Executing SQL via pipe...');

    // We use shell: true for the command to be properly parsed on Windows, but we rely on piping for the content.
    // 'docker exec -i CONTAINER psql -U postgres -d postgres'
    const child = spawn('docker', [
        'exec', '-i', dbContainer,
        'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'
    ], {
        shell: true,
        stdio: ['pipe', process.stdout, process.stderr]
    });

    child.stdin.write(sql);
    child.stdin.end();

    await new Promise((resolve, reject) => {
        child.on('exit', (code) => {
            if (code === 0) resolve();
            else reject(new Error(`Process exited with code ${code}`));
        });
        child.on('error', reject);
    });
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
