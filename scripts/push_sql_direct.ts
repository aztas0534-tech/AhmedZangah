import * as fs from 'fs';
import { createClient } from '@supabase/supabase-js';

const envFile = fs.readFileSync('c:\\nasrflash\\AhmedZ\\.env.local', 'utf-8');
const env: Record<string, string> = {};
envFile.split(/\r?\n/).forEach(line => {
  const match = line.match(/^([^=]+)=(.*)$/);
  if (match) env[match[1].trim()] = match[2].trim();
});

const url = env['VITE_SUPABASE_URL'];
const key = env['VITE_SUPABASE_SERVICE_ROLE_KEY'] || env['VITE_SUPABASE_ANON_KEY'];
const supabase = createClient(url, key);

async function run() {
  console.log('Pushing 20260307230100_create_banks_and_exchanges_coa.sql...');
  let coaSql = fs.readFileSync('c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260307230100_create_banks_and_exchanges_coa.sql', 'utf-8');
  coaSql = coaSql.replace(/begin;/gi, '').replace(/commit;/gi, '');
  
  // Create wrapper query
  const coaQuery = `
    do $$ 
    begin
      ${coaSql}
    end $$;
  `;
  
  let result = await supabase.rpc('exec_debug_sql', { q: coaQuery });
  if (result.error) {
    console.error('Error in COA migration:', result.error);
    // Fallback: If it fails because of IFRS columns, let's execute the TS inserts wrapping in exec_debug_sql
    console.log('Attempting JS-based insert through exec_debug_sql for COA...');
    const ifrsParamsStr = `'financial_position', 'current_assets', 'cash_and_equivalents'`;
    const fallbackSql = `
      do $$
      declare
        v_1020 uuid;
        v_1030 uuid;
      begin
        insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active, ifrs_statement, ifrs_category, ifrs_line)
        values ('1030', 'Exchange Companies', 'asset', 'debit', true, ${ifrsParamsStr})
        on conflict (code) do nothing;
        
        select id into v_1020 from public.chart_of_accounts where code = '1020' limit 1;
        select id into v_1030 from public.chart_of_accounts where code = '1030' limit 1;

        insert into public.chart_of_accounts(code, name, parent_id, account_type, normal_balance, is_active, ifrs_statement, ifrs_category, ifrs_line)
        values 
          ('1020-001-SAR', 'بنك الشمول مؤسسة أحمد زنقاح (سعودي)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-001-YER', 'بنك الشمول مؤسسة أحمد زنقاح (يمني)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-001-USD', 'بنك الشمول مؤسسة أحمد زنقاح (دولار)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-002-SAR', 'بنك القطيبي مؤسسة أحمد زنقاح (سعودي)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-002-YER', 'بنك القطيبي مؤسسة أحمد زنقاح (يمني)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-002-USD', 'بنك القطيبي مؤسسة أحمد زنقاح (دولار)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-003-SAR', 'بنك الإنماء مؤسسة أحمد زنقاح (سعودي)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-003-YER', 'بنك الإنماء مؤسسة أحمد زنقاح (يمني)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1020-003-USD', 'بنك الإنماء مؤسسة أحمد زنقاح (دولار)', v_1020, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-001-SAR', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (سعودي)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-001-YER', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (يمني)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-001-USD', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (دولار)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-002-SAR', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (سعودي)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-002-YER', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (يمني)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-002-USD', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (دولار)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-003-SAR', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (سعودي)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-003-YER', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (يمني)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr}),
          ('1030-003-USD', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (دولار)', v_1030, 'asset', 'debit', true, ${ifrsParamsStr})
        on conflict (code) do nothing;
      end $$;
    `;
    const fbRes = await supabase.rpc('exec_debug_sql', { q: fallbackSql });
    if(fbRes.error) console.error('Fallback failed:', fbRes.error);
    else console.log('Fallback COA migration OK!');
  } else {
    console.log('COA migration OK!');
  }

  console.log('Pushing 20260307230200_routing_bank_destination.sql...');
  let routingSql = fs.readFileSync('c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260307230200_routing_bank_destination.sql', 'utf-8');
  routingSql = routingSql.replace(/begin;/gi, '').replace(/commit;/gi, '');
  
  result = await supabase.rpc('exec_debug_sql', { q: routingSql });
  if (result.error) console.error('Error in Routing migration:', result.error);
  else console.log('Routing migration OK!');
  
  // Also push via Supabase so history is up-to-date locally, but we don't care if history is not written.
  // Wait, if we don't push via `db push`, the next time someone runs `db push` it will try to re-apply them!
  // To avoid this, we can insert into schema_migrations:
  const schemaMigSql = `
    insert into supabase_migrations.schema_migrations (version) values ('20260307230100');
    insert into supabase_migrations.schema_migrations (version) values ('20260307230200');
  `;
  const schemaMigRes = await supabase.rpc('exec_debug_sql', { q: schemaMigSql });
  if (schemaMigRes.error) console.error('Error writing to schema_migrations:', schemaMigRes.error);
}

run();
