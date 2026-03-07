-- Add 18 new accounts for Banks and Exchange Companies
-- Including a new Parent '1030' for Exchange Companies

begin;

-- 1. Ensure 1030 parent exists
insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
values ('1030', 'Exchange Companies', 'asset', 'debit', true)
on conflict (code) do nothing;

-- Function to get the ID of an account by its code
create or replace function pg_temp.get_acc_id_by_code(p_code text)
returns uuid
language sql
as $$
  select id from public.chart_of_accounts where code = p_code limit 1;
$$;

do $$
declare
  v_1020 uuid;
  v_1030 uuid;
begin
  v_1020 := pg_temp.get_acc_id_by_code('1020');
  v_1030 := pg_temp.get_acc_id_by_code('1030');

  -- 2. Banks (Under 1020)
  -- Al Shamil Bank
  insert into public.chart_of_accounts(code, name, parent_id, account_type, normal_balance, is_active)
  values 
    ('1020-001-SAR', 'بنك الشمول مؤسسة أحمد زنقاح (سعودي)', v_1020, 'asset', 'debit', true),
    ('1020-001-YER', 'بنك الشمول مؤسسة أحمد زنقاح (يمني)', v_1020, 'asset', 'debit', true),
    ('1020-001-USD', 'بنك الشمول مؤسسة أحمد زنقاح (دولار)', v_1020, 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Al Qutaibi Bank
  insert into public.chart_of_accounts(code, name, parent_id, account_type, normal_balance, is_active)
  values 
    ('1020-002-SAR', 'بنك القطيبي مؤسسة أحمد زنقاح (سعودي)', v_1020, 'asset', 'debit', true),
    ('1020-002-YER', 'بنك القطيبي مؤسسة أحمد زنقاح (يمني)', v_1020, 'asset', 'debit', true),
    ('1020-002-USD', 'بنك القطيبي مؤسسة أحمد زنقاح (دولار)', v_1020, 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Al Inma Bank
  insert into public.chart_of_accounts(code, name, parent_id, account_type, normal_balance, is_active)
  values 
    ('1020-003-SAR', 'بنك الإنماء مؤسسة أحمد زنقاح (سعودي)', v_1020, 'asset', 'debit', true),
    ('1020-003-YER', 'بنك الإنماء مؤسسة أحمد زنقاح (يمني)', v_1020, 'asset', 'debit', true),
    ('1020-003-USD', 'بنك الإنماء مؤسسة أحمد زنقاح (دولار)', v_1020, 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- 3. Exchange Companies (Under 1030)
  -- Al Muntab Exchange
  insert into public.chart_of_accounts(code, name, parent_id, account_type, normal_balance, is_active)
  values 
    ('1030-001-SAR', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (سعودي)', v_1030, 'asset', 'debit', true),
    ('1030-001-YER', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (يمني)', v_1030, 'asset', 'debit', true),
    ('1030-001-USD', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (دولار)', v_1030, 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Al Hatha Exchange
  insert into public.chart_of_accounts(code, name, parent_id, account_type, normal_balance, is_active)
  values 
    ('1030-002-SAR', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (سعودي)', v_1030, 'asset', 'debit', true),
    ('1030-002-YER', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (يمني)', v_1030, 'asset', 'debit', true),
    ('1030-002-USD', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (دولار)', v_1030, 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Abu Bilal Exchange
  insert into public.chart_of_accounts(code, name, parent_id, account_type, normal_balance, is_active)
  values 
    ('1030-003-SAR', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (سعودي)', v_1030, 'asset', 'debit', true),
    ('1030-003-YER', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (يمني)', v_1030, 'asset', 'debit', true),
    ('1030-003-USD', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (دولار)', v_1030, 'asset', 'debit', true)
  on conflict (code) do nothing;
end $$;

commit;
