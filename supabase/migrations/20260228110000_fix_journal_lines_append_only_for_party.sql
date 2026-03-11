set app.allow_ledger_ddl = '1';

create or replace function public.trg_block_system_journal_lines_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source_table text;
begin
  select je.source_table
  into v_source_table
  from public.journal_entries je
  where je.id = coalesce(new.journal_entry_id, old.journal_entry_id);

  if coalesce(v_source_table, '') <> '' and v_source_table <> 'manual' then
    if tg_op = 'DELETE' then
      raise exception 'GL is append-only: system journal lines cannot be deleted';
    end if;

    -- Only prevent updates to core financial columns
    if old.journal_entry_id is distinct from new.journal_entry_id
       or old.account_id is distinct from new.account_id
       or old.debit is distinct from new.debit
       or old.credit is distinct from new.credit
       or coalesce(old.currency_code, '') is distinct from coalesce(new.currency_code, '')
       or coalesce(old.fx_rate, 1) is distinct from coalesce(new.fx_rate, 1)
       or coalesce(old.base_debit, 0) is distinct from coalesce(new.base_debit, 0)
       or coalesce(old.base_credit, 0) is distinct from coalesce(new.base_credit, 0)
    then
      raise exception 'GL is append-only: system journal lines cannot be changed financially';
    end if;

    -- Allow updates to tracking/informational columns like party_id, open_status, dimensions etc.
    return new;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';
