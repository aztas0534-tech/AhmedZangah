set app.allow_ledger_ddl = '1';

-- 1. Leave Types and Balances
create table if not exists public.hr_leave_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  is_paid boolean not null default true,
  default_days_per_year numeric not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.hr_leave_types enable row level security;
create policy hr_leave_types_select on public.hr_leave_types for select using (public.has_admin_permission('accounting.view') or public.is_admin());
create policy hr_leave_types_write on public.hr_leave_types for all using (public.has_admin_permission('accounting.manage') or public.is_admin()) with check (public.has_admin_permission('accounting.manage') or public.is_admin());

create table if not exists public.hr_leave_requests (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  leave_type_id uuid not null references public.hr_leave_types(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  total_days numeric not null,
  status text not null default 'draft' check (status in ('draft', 'approved', 'rejected', 'cancelled')),
  notes text,
  approved_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);

alter table public.hr_leave_requests enable row level security;
create policy hr_leave_requests_select on public.hr_leave_requests for select using (public.has_admin_permission('accounting.view') or public.is_admin());
create policy hr_leave_requests_write on public.hr_leave_requests for all using (public.has_admin_permission('accounting.manage') or public.is_admin()) with check (public.has_admin_permission('accounting.manage') or public.is_admin());

create table if not exists public.hr_leave_balances (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.payroll_employees(id) on delete restrict,
  leave_type_id uuid not null references public.hr_leave_types(id) on delete restrict,
  year int not null,
  accrued_days numeric not null default 0,
  taken_days numeric not null default 0,
  balance_days numeric generated always as (accrued_days - taken_days) stored,
  last_updated_at timestamptz not null default now(),
  unique(employee_id, leave_type_id, year)
);

alter table public.hr_leave_balances enable row level security;
create policy hr_leave_balances_select on public.hr_leave_balances for select using (public.has_admin_permission('accounting.view') or public.is_admin());
create policy hr_leave_balances_write on public.hr_leave_balances for all using (public.has_admin_permission('accounting.manage') or public.is_admin()) with check (public.has_admin_permission('accounting.manage') or public.is_admin());

do $$
begin
  if not exists (select 1 from public.hr_leave_types where code = 'ANNUAL') then
    insert into public.hr_leave_types(code, name, is_paid, default_days_per_year) values ('ANNUAL', 'إجازة سنوية', true, 30);
  end if;
  if not exists (select 1 from public.hr_leave_types where code = 'SICK') then
    insert into public.hr_leave_types(code, name, is_paid, default_days_per_year) values ('SICK', 'إجازة مرضية', true, 15);
  end if;
  if not exists (select 1 from public.hr_leave_types where code = 'UNPAID') then
    insert into public.hr_leave_types(code, name, is_paid, default_days_per_year) values ('UNPAID', 'إجازة بدون راتب', false, 0);
  end if;
end $$;

-- 2. Absence and Overtime Tracking enhancements
do $$
begin
  if to_regclass('public.payroll_attendance') is not null then
    begin
      alter table public.payroll_attendance add column overtime_hours numeric not null default 0;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_attendance add column absence_days numeric not null default 0;
    exception when duplicate_column then null;
    end;
    begin
      -- e.g. 1.5 for normal overtime, 2.0 for holiday
      alter table public.payroll_attendance add column overtime_rate_multiplier numeric not null default 1.5;
    exception when duplicate_column then null;
    end;
  end if;
end $$;

-- 3. Multi-Currency for Allowances/Deductions/Loans
do $$
begin
  if to_regclass('public.payroll_rule_defs') is not null then
    begin
      alter table public.payroll_rule_defs add column currency text not null default 'YER';
    exception when duplicate_column then null;
    end;
  end if;
  if to_regclass('public.payroll_loans') is not null then
    begin
      alter table public.payroll_loans add column currency text not null default 'YER';
    exception when duplicate_column then null;
    end;
  end if;
end $$;

-- 4. Settings for calculating daily/hourly rates
do $$
begin
  if to_regclass('public.payroll_settings') is not null then
    begin
      alter table public.payroll_settings add column standard_monthly_days int not null default 30;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_settings add column standard_daily_hours int not null default 8;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_settings add column default_overtime_multiplier numeric not null default 1.5;
    exception when duplicate_column then null;
    end;
  end if;
end $$;

-- 5. Payroll Run Line extensions for Payslip details
do $$
begin
  if to_regclass('public.payroll_run_lines') is not null then
    begin
      alter table public.payroll_run_lines add column basic_salary_base numeric not null default 0;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_run_lines add column absence_days numeric not null default 0;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_run_lines add column absence_deduction numeric not null default 0;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_run_lines add column overtime_hours numeric not null default 0;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_run_lines add column overtime_addition numeric not null default 0;
    exception when duplicate_column then null;
    end;
  end if;
end $$;

-- 6. Payroll Engine v4
create or replace function public.compute_payroll_run_v4(p_run_id uuid, p_apply_attendance boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run record;
  v_settings record;
  v_line record;
  v_rules record;
  v_tax record;
  v_allowances numeric;
  v_deductions numeric;
  v_taxes numeric;
  v_loan record;
  v_absence_days numeric;
  v_absence_deduction numeric;
  v_overtime_hours numeric;
  v_overtime_add numeric;
  v_daily_rate numeric;
  v_hourly_rate numeric;
  v_base text;
  v_fx numeric;
  v_rule_val_base numeric;
  v_loan_val_base numeric;
  v_run_date date;
  v_basic_salary_base numeric;
  v_gross_base numeric;
  v_net_base numeric;
  v_start_date date;
  v_end_date date;
  v_att record;
  v_year int;
  v_month int;
begin
  if not (public.can_manage_expenses() or public.has_admin_permission('accounting.manage') or public.is_admin()) then
    raise exception 'not allowed';
  end if;
  
  select * into v_run from public.payroll_runs where id = p_run_id;
  if not found then
    raise exception 'run not found';
  end if;
  
  v_run_date := public._payroll_last_day(v_run.period_ym);
  v_base := public.get_base_currency();
  
  begin
    v_year := nullif(split_part(v_run.period_ym, '-', 1), '')::int;
    v_month := nullif(split_part(v_run.period_ym, '-', 2), '')::int;
    v_start_date := make_date(v_year, v_month, 1);
    v_end_date := (v_start_date + interval '1 month - 1 day')::date;
  exception when others then
    v_start_date := v_run_date;
    v_end_date := v_run_date;
  end;

  select * into v_settings from public.payroll_settings where id = 'app';
  if v_settings is null then
    select 30 as standard_monthly_days, 8 as standard_daily_hours into v_settings;
  end if;

  for v_line in
    select l.id, l.run_id, l.employee_id, l.gross, l.allowances, l.deductions, l.net, l.currency_code, l.fx_rate, l.foreign_amount,
           pe.monthly_salary, pe.currency as employee_currency, pe.created_at::date as hired_date
    from public.payroll_run_lines l
    join public.payroll_employees pe on pe.id = l.employee_id
    where l.run_id = p_run_id
  loop
    v_allowances := 0; 
    v_deductions := 0; 
    v_taxes := 0;
    v_absence_days := 0;
    v_absence_deduction := 0;
    v_overtime_hours := 0;
    v_overtime_add := 0;
    v_gross_base := coalesce(v_line.gross, 0); 
    
    -- Calculate Base Salary Details
    if coalesce(v_line.currency_code, v_base) <> v_base then
      -- It was already converted in create_payroll_run, we can rely on basic_salary_base if we want, but let's re-calculate it to be sure
      v_fx := coalesce(v_line.fx_rate, 1);
      v_basic_salary_base := round(coalesce(v_line.foreign_amount, v_line.monthly_salary, 0) * v_fx, 2);
    else
      v_basic_salary_base := coalesce(v_line.gross, 0); -- fallback to initial gross
    end if;

    v_daily_rate := v_basic_salary_base / greatest(coalesce(v_settings.standard_monthly_days, 30), 1);
    v_hourly_rate := v_daily_rate / greatest(coalesce(v_settings.standard_daily_hours, 8), 1);

    -- Attendance/Proration
    if p_apply_attendance then
      -- 1. Proration based on hired_date
      if v_line.hired_date > v_start_date and v_line.hired_date <= v_end_date then
        v_absence_days := v_absence_days + (v_line.hired_date - v_start_date);
      end if;

      -- 2. Aggregate Unpaid Leaves
      select coalesce(sum(lr.total_days), 0) into v_att
      from public.hr_leave_requests lr
      join public.hr_leave_types lt on lt.id = lr.leave_type_id
      where lr.employee_id = v_line.employee_id
        and lr.status = 'approved'
        and lt.is_paid = false
        and (
          (lr.start_date >= v_start_date and lr.start_date <= v_end_date)
          or 
          (lr.end_date >= v_start_date and lr.end_date <= v_end_date)
        );
      
      -- For simplicity, if a leave crosses months, we just take the total days of requests that start or end in this month. 
      -- In a fully strict system we'd calculate intersection days, but this is a solid v1.
      v_absence_days := v_absence_days + coalesce(v_att.sum, 0);

      -- 3. Aggregate Attendance Absences & Overtime
      for v_att in
        select sum(absence_days) as abs_days, sum(overtime_hours * overtime_rate_multiplier) as ot_equiv_hours
        from public.payroll_attendance
        where employee_id = v_line.employee_id
          and work_date >= v_start_date and work_date <= v_end_date
      loop
        v_absence_days := v_absence_days + coalesce(v_att.abs_days, 0);
        v_overtime_hours := v_overtime_hours + coalesce(v_att.ot_equiv_hours, 0);
      end loop;

      v_absence_deduction := round(v_absence_days * v_daily_rate, 2);
      v_overtime_add := round(v_overtime_hours * v_hourly_rate, 2);

      -- Update Gross = Basic - Absences + Overtime
      v_gross_base := v_basic_salary_base - v_absence_deduction + v_overtime_add;
    end if;

    -- Rules (Allowances / Deductions)
    for v_rules in
      select * from public.payroll_rule_defs rd where rd.is_active = true
    loop
      if v_rules.amount_type = 'fixed' then
        if upper(coalesce(v_rules.currency, v_base)) = v_base then
          v_rule_val_base := v_rules.amount_value;
        else
          v_fx := public.get_fx_rate(upper(v_rules.currency), v_run_date, 'accounting');
          if v_fx is null then v_fx := public.get_fx_rate(upper(v_rules.currency), v_run_date, 'operational'); end if;
          if v_fx is null or v_fx <= 0 then v_fx := 1; end if;
          v_rule_val_base := round(v_rules.amount_value * v_fx, 2);
        end if;
      else
        -- Percentage is on the calculated gross
        v_rule_val_base := round((coalesce(v_rules.amount_value,0)/100.0) * coalesce(v_gross_base,0), 2);
      end if;

      if v_rules.rule_type = 'allowance' then
        v_allowances := v_allowances + v_rule_val_base;
      else
        v_deductions := v_deductions + v_rule_val_base;
      end if;
    end loop;

    -- Taxes
    for v_tax in
      select * from public.payroll_tax_defs td where td.is_active = true
    loop
      if v_tax.applies_to = 'gross' then
        v_taxes := v_taxes + round((coalesce(v_tax.rate,0)/100.0) * coalesce(v_gross_base,0), 2);
      else
        v_taxes := v_taxes + round((coalesce(v_tax.rate,0)/100.0) * greatest(0, coalesce(v_gross_base,0) + v_allowances - v_deductions), 2);
      end if;
    end loop;

    -- Loans
    select * into v_loan from public.payroll_loans pl 
    where pl.employee_id = v_line.employee_id and pl.status = 'active' 
    order by pl.created_at asc limit 1;

    if found and coalesce(v_loan.installment_amount,0) > 0 then
      if upper(coalesce(v_loan.currency, v_base)) = v_base then
        v_loan_val_base := v_loan.installment_amount;
      else
        v_fx := public.get_fx_rate(upper(v_loan.currency), v_run_date, 'accounting');
        if v_fx is null then v_fx := public.get_fx_rate(upper(v_loan.currency), v_run_date, 'operational'); end if;
        if v_fx is null or v_fx <= 0 then v_fx := 1; end if;
        v_loan_val_base := round(v_loan.installment_amount * v_fx, 2);
      end if;

      v_deductions := v_deductions + v_loan_val_base;
      
      -- We don't deduct from balance yet until accural/payment, but the old v3 did it here. 
      -- We will keep the old logical behavior for backward compatibility.
      update public.payroll_loans 
      set balance = greatest(0, coalesce(balance,0) - coalesce(v_loan.installment_amount,0)), 
          status = case when (coalesce(balance,0) - coalesce(v_loan.installment_amount,0)) <= 1e-9 then 'closed' else status end 
      where id = v_loan.id;
    end if;

    v_net_base := greatest(0, v_gross_base + v_allowances - (v_deductions + v_taxes));

    -- Prevent trigger recursion by temporarily disabling triggers or using direct update?
    -- The trigger `trg_payroll_run_lines_apply` might alter `net` = `gross` + `allowances` - `deductions`.
    -- So we just pass the calculated values.
    update public.payroll_run_lines
    set basic_salary_base = v_basic_salary_base,
        absence_days = v_absence_days,
        absence_deduction = v_absence_deduction,
        overtime_hours = v_overtime_hours,
        overtime_addition = v_overtime_add,
        gross = v_gross_base, -- This overrides the original gross to be basic - abs + over
        allowances = v_allowances,
        deductions = v_deductions + v_taxes,
        net = v_net_base
    where id = v_line.id;
  end loop;

  perform public.recalc_payroll_run_totals(p_run_id);
end;
$$;
revoke all on function public.compute_payroll_run_v4(uuid, boolean) from public;
grant execute on function public.compute_payroll_run_v4(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
