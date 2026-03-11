-- Fix list_active_accounts: qualify column references to avoid clash
-- between OUT parameters (id, code, name) and table columns.
-- The function returns TABLE(id uuid, code text, name text, ...) which
-- creates plpgsql variables that clash with chart_of_accounts columns.

create or replace function public.list_active_accounts()
returns table(id uuid, code text, name text, account_type text, normal_balance text)
language plpgsql
stable security definer
set search_path = public
as $$
begin
  if not public.has_admin_permission('accounting.view') then
    raise exception 'not allowed';
  end if;
  return query
  select coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance
  from public.chart_of_accounts coa
  where coa.is_active = true
  order by coa.code asc;
end;
$$;

-- Fix currencies table: add current_exchange_rate column if missing
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'currencies' and column_name = 'current_exchange_rate'
  ) then
    alter table public.currencies add column current_exchange_rate numeric default 1;
  end if;
end
$$;

notify pgrst, 'reload schema';
