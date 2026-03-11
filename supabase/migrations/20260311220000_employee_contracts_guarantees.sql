-- ============================================================
-- Employee Contracts & Guarantees
-- Additive migration – zero impact on existing tables/functions
-- ============================================================

-- 1) employee_contracts
create table if not exists public.employee_contracts (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  contract_number text,
  contract_type text not null default 'indefinite'
    check (contract_type in ('definite','indefinite','probation','part_time')),
  start_date date not null default current_date,
  end_date date,
  job_title text,
  department text,
  work_location text,
  salary numeric not null default 0,
  currency text not null default 'YER',
  salary_breakdown jsonb not null default '{}'::jsonb,
  probation_days int not null default 90,
  working_hours_per_day numeric not null default 8,
  working_days_per_week int not null default 6,
  vacation_days_annual int not null default 30,
  special_terms text,
  status text not null default 'draft'
    check (status in ('active','expired','terminated','draft')),
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);

create index if not exists idx_employee_contracts_employee on public.employee_contracts(employee_id);
create index if not exists idx_employee_contracts_status on public.employee_contracts(status);

alter table public.employee_contracts enable row level security;

drop policy if exists employee_contracts_select on public.employee_contracts;
create policy employee_contracts_select
on public.employee_contracts
for select
using (
  public.has_admin_permission('accounting.view')
  or public.has_admin_permission('expenses.manage')
  or public.is_admin()
);

drop policy if exists employee_contracts_write on public.employee_contracts;
create policy employee_contracts_write
on public.employee_contracts
for all
using (
  public.has_admin_permission('expenses.manage')
  or public.has_admin_permission('accounting.manage')
  or public.is_admin()
)
with check (
  public.has_admin_permission('expenses.manage')
  or public.has_admin_permission('accounting.manage')
  or public.is_admin()
);

-- 2) employee_guarantees
create table if not exists public.employee_guarantees (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  guarantee_number text,
  guarantee_type text not null default 'personal'
    check (guarantee_type in ('personal','financial','property')),
  guarantor_name text not null,
  guarantor_id_number text,
  guarantor_phone text,
  guarantor_address text,
  guarantor_relationship text,
  guarantee_amount numeric not null default 0,
  currency text not null default 'YER',
  valid_from date not null default current_date,
  valid_until date,
  special_terms text,
  status text not null default 'active'
    check (status in ('active','expired','released')),
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);

create index if not exists idx_employee_guarantees_employee on public.employee_guarantees(employee_id);
create index if not exists idx_employee_guarantees_status on public.employee_guarantees(status);

alter table public.employee_guarantees enable row level security;

drop policy if exists employee_guarantees_select on public.employee_guarantees;
create policy employee_guarantees_select
on public.employee_guarantees
for select
using (
  public.has_admin_permission('accounting.view')
  or public.has_admin_permission('expenses.manage')
  or public.is_admin()
);

drop policy if exists employee_guarantees_write on public.employee_guarantees;
create policy employee_guarantees_write
on public.employee_guarantees
for all
using (
  public.has_admin_permission('expenses.manage')
  or public.has_admin_permission('accounting.manage')
  or public.is_admin()
)
with check (
  public.has_admin_permission('expenses.manage')
  or public.has_admin_permission('accounting.manage')
  or public.is_admin()
);

notify pgrst, 'reload schema';
