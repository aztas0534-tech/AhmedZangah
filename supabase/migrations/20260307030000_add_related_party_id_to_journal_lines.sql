set app.allow_ledger_ddl = '1';

alter table public.journal_lines
add column if not exists related_party_id uuid references public.financial_parties(id) on delete set null;

notify pgrst, 'reload schema';
