set app.allow_ledger_ddl = '1';

drop function if exists public.check_party_credit_limit(uuid, numeric);

notify pgrst, 'reload schema';
