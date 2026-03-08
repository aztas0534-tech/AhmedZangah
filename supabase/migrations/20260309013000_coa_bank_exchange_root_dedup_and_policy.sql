set app.allow_ledger_ddl = '1';

do $$
declare
  v_row record;
begin
  for v_row in
    with legacy as (
      select coa.id, coa.code
      from public.chart_of_accounts coa
      where coa.is_active = true
        and (
          coa.code ~ '^(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)-(1020|1030)-[0-9]{3}$'
          or coa.code ~ '^(1020|1030)\.[0-9]+$'
        )
    )
    select l.id, l.code
    from legacy l
    where not exists (select 1 from public.journal_lines jl where jl.account_id = l.id)
      and not exists (select 1 from public.chart_of_accounts c where c.parent_id = l.id)
      and not exists (
        select 1
        from public.app_settings s
        cross join lateral jsonb_each_text(coalesce(s.data->'settings'->'accounting_accounts', '{}'::jsonb)) e
        where e.value = l.id::text
      )
  loop
    update public.chart_of_accounts
    set is_active = false
    where id = v_row.id;
  end loop;
end $$;

update public.chart_of_accounts c
set parent_id = p.id
from public.chart_of_accounts p
where c.code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$'
  and p.code = split_part(c.code, '-', 1)
  and (c.parent_id is distinct from p.id);

create or replace function public.trg_coa_bank_exchange_code_policy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_parent_id uuid;
begin
  if public._is_migration_actor() then
    return new;
  end if;

  v_code := btrim(coalesce(new.code, ''));
  if v_code = '' then
    return new;
  end if;

  if v_code ~ '^(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)-(1020|1030)-[0-9]{3}$'
     or v_code ~ '^(1020|1030)\.[0-9]+$'
  then
    raise exception 'legacy bank/exchange account code format is not allowed';
  end if;

  if v_code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$' then
    select id into v_parent_id
    from public.chart_of_accounts
    where code = split_part(v_code, '-', 1)
    limit 1;

    if v_parent_id is null then
      raise exception 'parent account % is required before creating %', split_part(v_code, '-', 1), v_code;
    end if;

    new.parent_id := v_parent_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_coa_bank_exchange_code_policy on public.chart_of_accounts;
create trigger trg_coa_bank_exchange_code_policy
before insert or update on public.chart_of_accounts
for each row
execute function public.trg_coa_bank_exchange_code_policy();

create or replace function public.create_chart_account(
  p_code text,
  p_name text,
  p_account_type text,
  p_normal_balance text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_name text;
  v_id uuid;
  v_parent_id uuid;
begin
  if not public.is_owner() then
    raise exception 'not allowed';
  end if;

  v_code := btrim(coalesce(p_code, ''));
  v_name := btrim(coalesce(p_name, ''));
  if v_code = '' then
    raise exception 'code is required';
  end if;
  if not (
    v_code ~ '^[0-9]{3,10}$'
    or v_code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$'
  ) then
    raise exception 'invalid code';
  end if;
  if v_name = '' then
    raise exception 'name is required';
  end if;
  if coalesce(p_account_type,'') not in ('asset','liability','equity','income','expense') then
    raise exception 'invalid account_type';
  end if;
  if coalesce(p_normal_balance,'') not in ('debit','credit') then
    raise exception 'invalid normal_balance';
  end if;

  if v_code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$' then
    select id into v_parent_id
    from public.chart_of_accounts
    where code = split_part(v_code, '-', 1)
    limit 1;
    if v_parent_id is null then
      raise exception 'parent account % is required', split_part(v_code, '-', 1);
    end if;
  end if;

  insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active, parent_id)
  values (v_code, v_name, p_account_type, p_normal_balance, true, v_parent_id)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.update_chart_account(
  p_account_id uuid,
  p_code text default null,
  p_name text default null,
  p_account_type text default null,
  p_normal_balance text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing record;
  v_used boolean;
  v_next_code text;
  v_next_name text;
  v_next_type text;
  v_next_balance text;
  v_parent_id uuid;
begin
  if not public.is_owner() then
    raise exception 'not allowed';
  end if;
  if p_account_id is null then
    raise exception 'account_id is required';
  end if;

  select *
  into v_existing
  from public.chart_of_accounts coa
  where coa.id = p_account_id
  for update;
  if not found then
    raise exception 'account not found';
  end if;

  select exists(select 1 from public.journal_lines jl where jl.account_id = p_account_id)
  into v_used;

  v_next_code := btrim(coalesce(p_code, v_existing.code));
  v_next_name := btrim(coalesce(p_name, v_existing.name));
  v_next_type := coalesce(p_account_type, v_existing.account_type);
  v_next_balance := coalesce(p_normal_balance, v_existing.normal_balance);

  if v_next_code = '' then
    raise exception 'code is required';
  end if;
  if not (
    v_next_code ~ '^[0-9]{3,10}$'
    or v_next_code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$'
  ) then
    raise exception 'invalid code';
  end if;
  if v_next_name = '' then
    raise exception 'name is required';
  end if;
  if coalesce(v_next_type,'') not in ('asset','liability','equity','income','expense') then
    raise exception 'invalid account_type';
  end if;
  if coalesce(v_next_balance,'') not in ('debit','credit') then
    raise exception 'invalid normal_balance';
  end if;

  if v_used then
    if v_next_code is distinct from v_existing.code
      or v_next_type is distinct from v_existing.account_type
      or v_next_balance is distinct from v_existing.normal_balance
    then
      raise exception 'account is used and cannot change code/type/balance';
    end if;
  end if;

  if v_next_code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$' then
    select id into v_parent_id
    from public.chart_of_accounts
    where code = split_part(v_next_code, '-', 1)
    limit 1;
    if v_parent_id is null then
      raise exception 'parent account % is required', split_part(v_next_code, '-', 1);
    end if;
  else
    v_parent_id := null;
  end if;

  update public.chart_of_accounts
  set code = v_next_code,
      name = v_next_name,
      account_type = v_next_type,
      normal_balance = v_next_balance,
      parent_id = coalesce(v_parent_id, parent_id)
  where id = p_account_id;
end;
$$;

notify pgrst, 'reload schema';
