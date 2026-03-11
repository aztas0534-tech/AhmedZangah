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

const main = async () => {
  const { data, error } = await supabase
    .from('orders')
    .select('id, status, data, created_at')
    .eq('status', 'delivered')
    .order('created_at', { ascending: false })
    .limit(10);
  if (error) {
    console.error('query error:', error.message || error);
    process.exit(1);
  }
  const rows = Array.isArray(data) ? data : [];
  const report = rows.map((r) => {
    const d = (r && r.data) || {};
    const snap = d.invoiceSnapshot || {};
    const ok =
      snap &&
      typeof snap === 'object' &&
      typeof snap.currency === 'string' &&
      typeof snap.fxRate !== 'undefined' &&
      typeof snap.baseCurrency === 'string' &&
      Array.isArray(snap.items);
    return {
      id: r.id,
      created_at: r.created_at,
      hasSnapshot: Boolean(d && d.invoiceSnapshot),
      fieldsOk: ok,
      currency: snap?.currency || null,
      baseCurrency: snap?.baseCurrency || null,
      itemsCount: Array.isArray(snap?.items) ? snap.items.length : 0,
    };
  });
  console.log(JSON.stringify(report, null, 2));
};

main().catch((e) => {
  console.error(String(e?.message || e));
  process.exit(1);
});
