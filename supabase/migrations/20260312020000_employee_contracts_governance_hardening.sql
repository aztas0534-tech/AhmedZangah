set app.allow_ledger_ddl = '1';

create sequence if not exists public.employee_contract_number_seq start 1;
create sequence if not exists public.employee_guarantee_number_seq start 1;

do $$
begin
  if to_regclass('public.employee_contracts') is not null then
    begin
      alter table public.employee_contracts alter column created_by set default auth.uid();
    exception when others then null;
    end;
    begin
      alter table public.employee_contracts add column updated_at timestamptz not null default now();
    exception when duplicate_column then null;
    end;
    begin
      alter table public.employee_contracts add column updated_by uuid references auth.users(id) on delete set null;
    exception when duplicate_column then null;
    end;
    if not exists (
      select 1 from pg_constraint
      where conname = 'employee_contracts_end_after_start_ck'
        and conrelid = 'public.employee_contracts'::regclass
    ) then
      alter table public.employee_contracts
        add constraint employee_contracts_end_after_start_ck
        check (end_date is null or end_date >= start_date);
    end if;
    if not exists (
      select 1 from pg_constraint
      where conname = 'employee_contracts_salary_nonneg_ck'
        and conrelid = 'public.employee_contracts'::regclass
    ) then
      alter table public.employee_contracts
        add constraint employee_contracts_salary_nonneg_ck
        check (salary >= 0);
    end if;
    create unique index if not exists uq_employee_contracts_contract_number
      on public.employee_contracts ((upper(trim(contract_number))))
      where nullif(trim(contract_number), '') is not null;
    create unique index if not exists uq_employee_contracts_employee_active
      on public.employee_contracts (employee_id)
      where status = 'active';
  end if;

  if to_regclass('public.employee_guarantees') is not null then
    begin
      alter table public.employee_guarantees alter column created_by set default auth.uid();
    exception when others then null;
    end;
    begin
      alter table public.employee_guarantees add column updated_at timestamptz not null default now();
    exception when duplicate_column then null;
    end;
    begin
      alter table public.employee_guarantees add column updated_by uuid references auth.users(id) on delete set null;
    exception when duplicate_column then null;
    end;
    if not exists (
      select 1 from pg_constraint
      where conname = 'employee_guarantees_until_after_from_ck'
        and conrelid = 'public.employee_guarantees'::regclass
    ) then
      alter table public.employee_guarantees
        add constraint employee_guarantees_until_after_from_ck
        check (valid_until is null or valid_until >= valid_from);
    end if;
    if not exists (
      select 1 from pg_constraint
      where conname = 'employee_guarantees_amount_nonneg_ck'
        and conrelid = 'public.employee_guarantees'::regclass
    ) then
      alter table public.employee_guarantees
        add constraint employee_guarantees_amount_nonneg_ck
        check (guarantee_amount >= 0);
    end if;
    create unique index if not exists uq_employee_guarantees_guarantee_number
      on public.employee_guarantees ((upper(trim(guarantee_number))))
      where nullif(trim(guarantee_number), '') is not null;
  end if;
end $$;

create or replace function public.tg_employee_contracts_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.contract_number is null or nullif(trim(new.contract_number), '') is null then
    new.contract_number := 'EC-' || lpad(nextval('public.employee_contract_number_seq')::text, 6, '0');
  else
    new.contract_number := upper(trim(new.contract_number));
  end if;
  if new.end_date is not null and new.end_date < current_date and new.status = 'active' then
    new.status := 'expired';
  end if;
  if tg_op = 'INSERT' and new.created_by is null then
    new.created_by := auth.uid();
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

create or replace function public.tg_employee_guarantees_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.guarantee_number is null or nullif(trim(new.guarantee_number), '') is null then
    new.guarantee_number := 'EG-' || lpad(nextval('public.employee_guarantee_number_seq')::text, 6, '0');
  else
    new.guarantee_number := upper(trim(new.guarantee_number));
  end if;
  if new.valid_until is not null and new.valid_until < current_date and new.status = 'active' then
    new.status := 'expired';
  end if;
  if tg_op = 'INSERT' and new.created_by is null then
    new.created_by := auth.uid();
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

drop trigger if exists trg_employee_contracts_guard on public.employee_contracts;
create trigger trg_employee_contracts_guard
before insert or update on public.employee_contracts
for each row execute function public.tg_employee_contracts_guard();

drop trigger if exists trg_employee_guarantees_guard on public.employee_guarantees;
create trigger trg_employee_guarantees_guard
before insert or update on public.employee_guarantees
for each row execute function public.tg_employee_guarantees_guard();

notify pgrst, 'reload schema';
