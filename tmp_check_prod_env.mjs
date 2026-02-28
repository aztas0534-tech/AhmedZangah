import fs from 'fs';

let envLocal = '';
try { envLocal = fs.readFileSync('.env.production', 'utf8'); } catch (e) { console.error(e); }

for (const line of envLocal.split('\n')) {
    if (line.includes('SUPABASE')) {
        console.log(line);
    }
}
