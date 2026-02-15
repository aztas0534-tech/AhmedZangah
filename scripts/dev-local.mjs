import { spawn } from 'node:child_process';

const run = (label, cmd, args, opts = {}) => {
  const child = spawn(cmd, args, { stdio: 'inherit', shell: true, ...opts });
  child.on('exit', (code, signal) => {
    if (signal) return;
    if (code && code !== 0) process.stderr.write(`[${label}] exited with code ${code}\n`);
  });
  return { child, done: new Promise((resolve) => child.on('exit', resolve)) };
};

const runCapture = (label, cmd, args, opts = {}) => new Promise((resolve) => {
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

const children = [];

const main = async () => {
  const start = run('supabase:start', 'npx', ['supabase', 'start']);
  children.push(start.child);
  const startCode = await start.done;
  if (startCode && startCode !== 0) process.exit(Number(startCode));

  const migrate = run('supabase:migrate', 'npx', ['supabase', 'migration', 'up', '--local']);
  children.push(migrate.child);
  const migrateCode = await migrate.done;
  if (migrateCode && migrateCode !== 0) process.exit(Number(migrateCode));

  try {
    const ps = await runCapture('docker:ps', 'docker', ['ps', '--format', '{{.Names}}']);
    const dbContainer = String(ps.stdout || '')
      .split(/\r?\n/g)
      .map(s => s.trim())
      .filter(Boolean)
      .find(n => n.startsWith('supabase_db_'));
    if (ps.code === 0 && dbContainer) {
      const sql = `
do $$
begin
  if to_regclass('public.journals') is null then
    return;
  end if;
  insert into public.journals(id, code, name, is_default, is_active)
  values ('00000000-0000-4000-8000-000000000001'::uuid, 'GEN', 'دفتر اليومية العام', true, true)
  on conflict (id) do update
  set code = excluded.code,
      name = excluded.name,
      is_default = true,
      is_active = true;
  update public.journals
  set is_default = false
  where id <> '00000000-0000-4000-8000-000000000001'::uuid
    and is_default = true;
exception when others then
  null;
end $$;
`.trim();
      const repair = run('db:repair:journals', 'docker', [
        'exec', '-i', dbContainer,
        'psql', '-U', 'postgres', '-d', 'postgres',
        '-v', 'ON_ERROR_STOP=1',
        '-c', sql,
      ]);
      children.push(repair.child);
      await repair.done;
    }
  } catch {
  }

  const fn = run('supabase:functions', 'npx', ['supabase', 'functions', 'serve', 'create-admin-customer', 'create-admin-user', 'reset-admin-password', 'delete-admin-user', '--no-verify-jwt']);
  children.push(fn.child);

  const vite = run('vite', 'node', ['--max-old-space-size=8192', './node_modules/vite/bin/vite.js']);
  children.push(vite.child);

  const code = await Promise.race([fn.done, vite.done]);
  if (code && code !== 0) process.exit(Number(code));
};

const shutdown = () => {
  for (const c of children) {
    try {
      if (!c.killed) c.kill('SIGINT');
    } catch {
    }
  }
};

process.on('SIGINT', () => {
  shutdown();
  process.exit(0);
});
process.on('SIGTERM', () => {
  shutdown();
  process.exit(0);
});

main().catch((e) => {
  process.stderr.write(String(e?.stack || e) + '\n');
  shutdown();
  process.exit(1);
});
