import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const loadEnv = (filePath) => {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    for (const line of raw.split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith('#')) continue;
      const i = t.indexOf('=');
      if (i <= 0) continue;
      const k = t.slice(0, i).trim();
      let v = t.slice(i + 1).trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      if (!process.env[k]) process.env[k] = v;
    }
  } catch {}
};

const runNodeScript = async (scriptFile) => {
  return await new Promise((resolve, reject) => {
    const child = spawn('node', [scriptFile], { cwd: rootDir, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => {
      const s = String(d);
      stdout += s;
      process.stdout.write(s);
    });
    child.stderr.on('data', (d) => {
      const s = String(d);
      stderr += s;
      process.stderr.write(s);
    });
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`failed: ${scriptFile}\n${stderr || stdout}`));
        return;
      }
      const lines = stdout.split(/\r?\n/).map((x) => x.trim()).filter(Boolean);
      const last = lines[lines.length - 1] || '';
      resolve(last);
    });
  });
};

const postWebhook = async (url, payload) => {
  if (!url) return { sent: false };
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  return { sent: true, status: res.status, ok: res.ok };
};

loadEnv(path.join(rootDir, '.env.production'));
loadEnv(path.join(rootDir, '.env.local'));

if (!String(process.env.DBPW || process.env.SUPABASE_DB_PASSWORD || '').trim()) {
  throw new Error('Missing DBPW or SUPABASE_DB_PASSWORD');
}

const startedAt = new Date().toISOString();
const scanPath = await runNodeScript(path.join('scripts', 'scan-similar-anomalies-prod.mjs'));
const auditPath = await runNodeScript(path.join('scripts', 'audit-stock-integrity-prod.mjs'));

const scan = JSON.parse(fs.readFileSync(scanPath, 'utf8'));
const audit = JSON.parse(fs.readFileSync(auditPath, 'utf8'));

const duplicateActive = Number(scan?.summary?.duplicateActiveReceiptItemGroups || 0);
const qtyInflation = Number(scan?.summary?.duplicateGroupsWithQtyInflation || 0);
const suspiciousCostMismatch = Number(scan?.summary?.suspiciousCostMismatchGroups || 0);
const qtyMismatch = Number(audit?.summary?.qty_mismatch_rows || 0);
const avgCostMismatch = Number(audit?.summary?.avg_cost_mismatch_rows || 0);
const negativeStock = Number(audit?.summary?.stock_negative_qty_rows || 0);
const negativeActiveRemaining = Number(audit?.summary?.active_batches_negative_remaining || 0);

const hasAnomaly = duplicateActive > 0 ||
  qtyInflation > 0 ||
  suspiciousCostMismatch > 0 ||
  qtyMismatch > 0 ||
  avgCostMismatch > 0 ||
  negativeStock > 0 ||
  negativeActiveRemaining > 0;

const result = {
  startedAt,
  finishedAt: new Date().toISOString(),
  hasAnomaly,
  metrics: {
    duplicateActive,
    qtyInflation,
    suspiciousCostMismatch,
    qtyMismatch,
    avgCostMismatch,
    negativeStock,
    negativeActiveRemaining,
  },
  sources: { scanPath, auditPath },
};

const outDir = path.join(rootDir, 'backups');
if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
const ts = new Date().toISOString().replace(/[:.]/g, '-');
const outPath = path.join(outDir, `stock_health_daily_check_${ts}.json`);
fs.writeFileSync(outPath, JSON.stringify(result, null, 2), 'utf8');

if (hasAnomaly) {
  const alertPayload = {
    text: `ALERT: stock health anomaly detected at ${result.finishedAt}`,
    ...result,
  };
  const webhook = String(process.env.ALERT_WEBHOOK_URL || '').trim();
  const webhookResult = await postWebhook(webhook, alertPayload);
  const alertPath = path.join(outDir, `stock_health_alert_${ts}.json`);
  fs.writeFileSync(alertPath, JSON.stringify({ ...alertPayload, webhookResult }, null, 2), 'utf8');
  console.log(JSON.stringify({ status: 'ALERT', outPath, alertPath, webhookResult }, null, 2));
  process.exit(2);
}

console.log(JSON.stringify({ status: 'OK', outPath }, null, 2));
