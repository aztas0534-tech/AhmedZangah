import * as fs from 'fs';
import { createClient } from '@supabase/supabase-js';

// Parse .env.local manually
const envFile = fs.readFileSync('c:\\nasrflash\\AhmedZ\\.env.local', 'utf-8');
const env: Record<string, string> = {};
envFile.split(/\r?\n/).forEach(line => {
  const match = line.match(/^([^=]+)=(.*)$/);
  if (match) env[match[1].trim()] = match[2].trim();
});

const url = env['VITE_SUPABASE_URL'];
const key = env['VITE_SUPABASE_SERVICE_ROLE_KEY'] || env['VITE_SUPABASE_ANON_KEY'];

if(!url || !key) {
  console.error('Missing env vars URL or KEY');
  process.exit(1);
}

const supabase = createClient(url, key);

async function run() {
  try {
    console.log('Connecting to Supabase...');
    
    const ifrsParams = {
      ifrs_statement: 'financial_position',
      ifrs_category: 'current_assets',
      ifrs_line: 'cash_and_equivalents'
    };
    
    // Create '1030' Exceptionally first or Update it safely
    const { error: e1 } = await supabase.from('chart_of_accounts').upsert({
      code: '1030', name: 'Exchange Companies', account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams
    }, { onConflict: 'code' }).select();
    if (e1) {
      console.error(e1);
      throw e1;
    }
    
    const { data: p0, error: e0 } = await supabase.from('chart_of_accounts').select('id, code').in('code', ['1020', '1030']);
    if (e0) {
      console.error(e0);
      throw e0;
    }
    
    const v1020 = p0.find(a => a.code === '1020')?.id;
    const v1030 = p0.find(a => a.code === '1030')?.id;
    
    if(!v1020 || !v1030) throw new Error('Parents not found');
    
    const subs = [
      { code: '1020-001-SAR', name: 'بنك الشمول مؤسسة أحمد زنقاح (سعودي)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-001-YER', name: 'بنك الشمول مؤسسة أحمد زنقاح (يمني)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-001-USD', name: 'بنك الشمول مؤسسة أحمد زنقاح (دولار)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-002-SAR', name: 'بنك القطيبي مؤسسة أحمد زنقاح (سعودي)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-002-YER', name: 'بنك القطيبي مؤسسة أحمد زنقاح (يمني)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-002-USD', name: 'بنك القطيبي مؤسسة أحمد زنقاح (دولار)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-003-SAR', name: 'بنك الإنماء مؤسسة أحمد زنقاح (سعودي)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-003-YER', name: 'بنك الإنماء مؤسسة أحمد زنقاح (يمني)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1020-003-USD', name: 'بنك الإنماء مؤسسة أحمد زنقاح (دولار)', parent_id: v1020, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      
      { code: '1030-001-SAR', name: 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (سعودي)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-001-YER', name: 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (يمني)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-001-USD', name: 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (دولار)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-002-SAR', name: 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (سعودي)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-002-YER', name: 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (يمني)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-002-USD', name: 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (دولار)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-003-SAR', name: 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (سعودي)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-003-YER', name: 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (يمني)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams },
      { code: '1030-003-USD', name: 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (دولار)', parent_id: v1030, account_type: 'asset', normal_balance: 'debit', is_active: true, ...ifrsParams }
    ];
    
    const { error: e2 } = await supabase.from('chart_of_accounts').upsert(subs, { onConflict: 'code' });
    if(e2) {
      console.error(e2);
      throw e2;
    }
    
    console.log("Success! 18 accounts created.");
  } catch(e) {
    console.error('Failed to create accounts:', e);
  }
}

run();
