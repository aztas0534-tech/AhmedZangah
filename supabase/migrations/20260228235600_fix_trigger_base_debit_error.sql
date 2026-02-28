-- Fix the trigger function that enforces journal line append-only logic for parties
-- It was incorrectly referencing base_debit and base_credit which do not exist on journal_lines

create or replace function public.enforce_journal_line_integrity_for_party_v2()
returns trigger
language plpgsql
security definer
as $$
declare
  v_is_party boolean;
begin
  -- Check if the line belongs to a party account (1200 or 2010 codes)
  select exists (
    select 1 from public.chart_of_accounts
    where id = coalesce(new.account_id, old.account_id)
      and account_code in ('1200', '2010')
  ) into v_is_party;

  -- Only enforce append-only rules for party accounts
  if v_is_party then
    
    if tg_op = 'DELETE' then
      raise exception 'ACCOUNTING_LOCKED_PARTY_DELETION';
    end if;

    if tg_op = 'UPDATE' then
      -- Prevent modifying core financial fields for party entries
      if coalesce(old.debit, 0) is distinct from coalesce(new.debit, 0)
         or coalesce(old.credit, 0) is distinct from coalesce(new.credit, 0)
         or old.account_id is distinct from new.account_id
         or coalesce(old.party_id, '00000000-0000-0000-0000-000000000000'::uuid) is distinct from coalesce(new.party_id, '00000000-0000-0000-0000-000000000000'::uuid)
         or coalesce(old.currency, 'YER') is distinct from coalesce(new.currency, 'YER')
         or coalesce(old.fx_rate, 1) is distinct from coalesce(new.fx_rate, 1)
      then
        raise exception 'ACCOUNTING_LOCKED_PARTY_UPDATE';
      end if;
    end if;
    
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
