import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';

const readEnv = () => {
  const p = path.join(process.cwd(), '.env.production');
  const txt = fs.readFileSync(p, 'utf8');
  const get = (k) => {
    const m = txt.split(/\r?\n/).find((l) => l.startsWith(k + '='));
    return m ? m.slice(k.length + 1).trim() : '';
  };
  return {
    url: get('VITE_SUPABASE_URL'),
    anon: get('VITE_SUPABASE_ANON_KEY'),
  };
};

const env = readEnv();
if (!env.url || !env.anon) {
  console.error('missing env');
  process.exit(1);
}

const supabase = createClient(env.url, env.anon);

const out = { session: false, createdUser: false, checks: {}, errors: {} };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const tryCreateAdmin = async () => {
  try {
    const email = `diag-${Date.now()}@azta.com`;
    const password = `Diag@${Math.random().toString(36).slice(2)}${Date.now()}`;
    const res = await supabase.functions.invoke('create-admin-user', {
      body: { email, password, fullName: 'Diag', role: 'owner' },
    });
    if (res.error) return null;
    out.createdUser = true;
    const si = await supabase.auth.signInWithPassword({ email, password });
    if (si.error) return null;
    out.session = true;
    return { email, password };
  } catch {
    return null;
  }
};

const ensureSession = async () => {
  const s = await supabase.auth.getSession();
  if (s.data?.session) {
    out.session = true;
    return true;
  }
  const created = await tryCreateAdmin();
  if (created) return true;
  return false;
};

const candidates = [
  'public.confirm_order_delivery_with_credit_rpc(uuid,jsonb,jsonb,uuid)',
  'public.confirm_order_delivery_with_credit(jsonb)',
  'public.confirm_order_delivery_with_credit(uuid,jsonb,jsonb,uuid)',
  'public.confirm_order_delivery_rpc(uuid,jsonb,jsonb,uuid)',
  'public.confirm_order_delivery(jsonb)',
  'public.confirm_order_delivery(uuid,jsonb,jsonb,uuid)',
  'public.record_order_payment_v2(uuid,numeric,text,timestamptz,text,text)',
  'public.record_order_payment(uuid,numeric,text,timestamptz,text,text)',
  'public.record_order_payment(uuid,numeric,text,timestamptz,text)',
  'public.record_order_payment(uuid,numeric,text,timestamptz)',
];

const main = async () => {
  await ensureSession();
  for (const name of candidates) {
    try {
      const { data, error } = await supabase.rpc('rpc_has_function', { p_name: name });
      if (error) {
        out.errors[name] = String(error.message || error.code || 'error');
        out.checks[name] = null;
      } else {
        out.checks[name] = Boolean(data);
      }
    } catch (e) {
      out.errors[name] = String(e?.message || 'error');
      out.checks[name] = null;
    }
    await sleep(50);
  }
  try { fs.writeFileSync(path.join(process.cwd(), 'RPC_DIAG.json'), JSON.stringify(out, null, 2), 'utf8'); } catch {}
  console.log(JSON.stringify(out, null, 2));
};

main().catch((e) => {
  console.error(String(e?.message || e));
  process.exit(1);
});
