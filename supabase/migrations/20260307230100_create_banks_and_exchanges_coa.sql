-- Add 18 new accounts for Banks and Exchange Companies
-- Including a new Parent '1030' for Exchange Companies

begin;

-- 1. Ensure 1030 parent exists
insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
values ('1030', 'Exchange Companies', 'asset', 'debit', true)
on conflict (code) do nothing;

do $$
begin

  -- 2. Banks (Under 1020 conceptually, but parent_id not in table)
  -- Al Shamil Bank
  insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
  values 
    ('1020-001-SAR', 'بنك الشمول مؤسسة أحمد زنقاح (سعودي)', 'asset', 'debit', true),
    ('1020-001-YER', 'بنك الشمول مؤسسة أحمد زنقاح (يمني)', 'asset', 'debit', true),
    ('1020-001-USD', 'بنك الشمول مؤسسة أحمد زنقاح (دولار)', 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Al Qutaibi Bank
  insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
  values 
    ('1020-002-SAR', 'بنك القطيبي مؤسسة أحمد زنقاح (سعودي)', 'asset', 'debit', true),
    ('1020-002-YER', 'بنك القطيبي مؤسسة أحمد زنقاح (يمني)', 'asset', 'debit', true),
    ('1020-002-USD', 'بنك القطيبي مؤسسة أحمد زنقاح (دولار)', 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Al Inma Bank
  insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
  values 
    ('1020-003-SAR', 'بنك الإنماء مؤسسة أحمد زنقاح (سعودي)', 'asset', 'debit', true),
    ('1020-003-YER', 'بنك الإنماء مؤسسة أحمد زنقاح (يمني)', 'asset', 'debit', true),
    ('1020-003-USD', 'بنك الإنماء مؤسسة أحمد زنقاح (دولار)', 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- 3. Exchange Companies (Under 1030 conceptually)
  -- Al Muntab Exchange
  insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
  values 
    ('1030-001-SAR', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (سعودي)', 'asset', 'debit', true),
    ('1030-001-YER', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (يمني)', 'asset', 'debit', true),
    ('1030-001-USD', 'شركة المنتاب للصرافة مؤسسة أحمد زنقاح (دولار)', 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Al Hatha Exchange
  insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
  values 
    ('1030-002-SAR', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (سعودي)', 'asset', 'debit', true),
    ('1030-002-YER', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (يمني)', 'asset', 'debit', true),
    ('1030-002-USD', 'شركة الحظاء للصرافة مؤسسة أحمد زنقاح (دولار)', 'asset', 'debit', true)
  on conflict (code) do nothing;

  -- Abu Bilal Exchange
  insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active)
  values 
    ('1030-003-SAR', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (سعودي)', 'asset', 'debit', true),
    ('1030-003-YER', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (يمني)', 'asset', 'debit', true),
    ('1030-003-USD', 'شركة ابو بلال للصرافة مؤسسة أحمد زنقاح (دولار)', 'asset', 'debit', true)
  on conflict (code) do nothing;
end $$;

commit;
