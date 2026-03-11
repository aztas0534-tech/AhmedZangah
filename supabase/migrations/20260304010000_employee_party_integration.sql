set app.allow_ledger_ddl = '1';

-- ============================================================
-- 1. Add party_id to payroll_employees (links to financial_parties)
-- ============================================================
do $$
begin
  if to_regclass('public.payroll_employees') is not null then
    begin
      alter table public.payroll_employees
        add column party_id uuid references public.financial_parties(id) on delete set null;
    exception when duplicate_column then null;
    end;

    -- Add credit limit multiplier setting
    begin
      alter table public.payroll_employees
        add column credit_limit_multiplier numeric not null default 2;
    exception when duplicate_column then null;
    end;

    -- Add auto_deduct_ar setting per employee
    begin
      alter table public.payroll_employees
        add column auto_deduct_ar boolean not null default true;
    exception when duplicate_column then null;
    end;
  end if;
end $$;

-- Add payroll setting for global credit limit multiplier default
do $$
begin
  if to_regclass('public.payroll_settings') is not null then
    begin
      alter table public.payroll_settings
        add column employee_credit_multiplier numeric not null default 2;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_settings
        add column auto_deduct_employee_ar boolean not null default true;
    exception when duplicate_column then null;
    end;
  end if;
end $$;

-- Add ar_deduction and party_ar_balance columns to payroll_run_lines
do $$
begin
  if to_regclass('public.payroll_run_lines') is not null then
    begin
      alter table public.payroll_run_lines add column ar_deduction numeric not null default 0;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.payroll_run_lines add column party_ar_balance numeric not null default 0;
    exception when duplicate_column then null;
    end;
  end if;
end $$;

-- ============================================================
-- 2. Backfill party_id for existing employees
-- ============================================================
do $$
declare
  r record;
  v_party_id uuid;
begin
  if to_regclass('public.payroll_employees') is null or to_regclass('public.financial_parties') is null then
    return;
  end if;
  
  for r in 
    select pe.id, pe.full_name, pe.currency
    from public.payroll_employees pe
    where pe.party_id is null
  loop
    -- Check if party already exists via link table
    select fpl.party_id into v_party_id
    from public.financial_party_links fpl
    where fpl.linked_entity_type = 'payroll_employees'
      and fpl.linked_entity_id = r.id::text
      and fpl.role = 'employee'
    limit 1;
    
    if v_party_id is null then
      -- Create financial party
      insert into public.financial_parties(name, party_type, linked_entity_type, linked_entity_id, currency_preference)
      values (r.full_name, 'employee', 'payroll_employees', r.id::text, r.currency)
      returning id into v_party_id;
      
      insert into public.financial_party_links(party_id, role, linked_entity_type, linked_entity_id)
      values (v_party_id, 'employee', 'payroll_employees', r.id::text)
      on conflict (linked_entity_type, linked_entity_id, role) do nothing;
    end if;
    
    -- Update employee with party_id
    update public.payroll_employees set party_id = v_party_id where id = r.id;
    
    -- Set credit limit = monthly_salary × 2 on the financial party
    update public.financial_parties
    set credit_limit_base = (
      select coalesce(pe.monthly_salary, 0) * coalesce(pe.credit_limit_multiplier, 2)
      from public.payroll_employees pe
      where pe.id = r.id
    )
    where id = v_party_id
      and coalesce(credit_limit_base, 0) = 0;
  end loop;
end $$;

-- ============================================================
-- 3. Update trigger to also set party_id + credit limit on insert/update
-- ============================================================
create or replace function public.trg_payroll_employees_ensure_financial_party()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party_id uuid;
begin
  -- Ensure financial party exists
  v_party_id := public.ensure_financial_party_for_employee(new.id);
  
  if v_party_id is not null then
    -- Set party_id on the employee
    if new.party_id is distinct from v_party_id then
      new.party_id := v_party_id;
    end if;
    
    -- Sync financial party name and credit limit
    update public.financial_parties
    set name = new.full_name,
        currency_preference = new.currency,
        credit_limit_base = coalesce(new.monthly_salary, 0) * coalesce(new.credit_limit_multiplier, 2),
        is_active = new.is_active,
        updated_at = now()
    where id = v_party_id;
  end if;
  
  return new;
end;
$$;

-- Recreate trigger as BEFORE INSERT OR UPDATE (not AFTER)
drop trigger if exists trg_payroll_employees_ensure_financial_party on public.payroll_employees;
create trigger trg_payroll_employees_ensure_financial_party
before insert or update on public.payroll_employees
for each row execute function public.trg_payroll_employees_ensure_financial_party();

-- ============================================================
-- 4. Update compute_payroll_run_v4 to include AR deduction
-- ============================================================
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
  v_leave_start date;
  v_leave_end date;
  v_intersect_days numeric;
  v_ar_balance numeric;
  v_ar_deduction numeric;
  v_party_id uuid;
  v_auto_deduct boolean;
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
    select 30 as standard_monthly_days, 8 as standard_daily_hours, 1.5 as default_overtime_multiplier,
           true as auto_deduct_employee_ar into v_settings;
  end if;

  for v_line in
    select l.id, l.run_id, l.employee_id, l.gross, l.allowances, l.deductions, l.net, l.currency_code, l.fx_rate, l.foreign_amount,
           pe.monthly_salary, pe.currency as employee_currency, 
           coalesce(pe.hired_date, pe.created_at::date) as hired_date,
           pe.party_id,
           coalesce(pe.auto_deduct_ar, true) as employee_auto_deduct
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
    v_ar_balance := 0;
    v_ar_deduction := 0;
    v_party_id := v_line.party_id;
    v_auto_deduct := coalesce(v_settings.auto_deduct_employee_ar, true) and coalesce(v_line.employee_auto_deduct, true);
    v_gross_base := coalesce(v_line.gross, 0); 
    
    -- Calculate Base Salary in base currency
    if coalesce(v_line.currency_code, v_base) <> v_base then
      v_fx := coalesce(v_line.fx_rate, 1);
      v_basic_salary_base := round(coalesce(v_line.foreign_amount, v_line.monthly_salary, 0) * v_fx, 2);
    else
      v_basic_salary_base := coalesce(v_line.gross, 0);
    end if;

    v_daily_rate := v_basic_salary_base / greatest(coalesce(v_settings.standard_monthly_days, 30), 1);
    v_hourly_rate := v_daily_rate / greatest(coalesce(v_settings.standard_daily_hours, 8), 1);

    -- Attendance/Proration
    if p_apply_attendance then
      -- 1. Proration based on hired_date
      if v_line.hired_date > v_start_date and v_line.hired_date <= v_end_date then
        v_absence_days := v_absence_days + (v_line.hired_date - v_start_date);
      end if;

      -- 2. Aggregate Unpaid Leaves WITH PROPER MONTH INTERSECTION
      for v_att in
        select lr.start_date, lr.end_date, lr.total_days
        from public.hr_leave_requests lr
        join public.hr_leave_types lt on lt.id = lr.leave_type_id
        where lr.employee_id = v_line.employee_id
          and lr.status = 'approved'
          and lt.is_paid = false
          and lr.start_date <= v_end_date
          and lr.end_date >= v_start_date
      loop
        v_leave_start := greatest(v_att.start_date, v_start_date);
        v_leave_end := least(v_att.end_date, v_end_date);
        v_intersect_days := greatest(0, (v_leave_end - v_leave_start) + 1);
        v_absence_days := v_absence_days + v_intersect_days;
      end loop;

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
      
      update public.payroll_loans 
      set balance = greatest(0, coalesce(balance,0) - coalesce(v_loan.installment_amount,0)), 
          status = case when (coalesce(balance,0) - coalesce(v_loan.installment_amount,0)) <= 1e-9 then 'closed' else status end 
      where id = v_loan.id;
    end if;

    -- AR Deduction (employee credit sales outstanding balance)
    if v_auto_deduct and v_party_id is not null then
      begin
        v_ar_balance := coalesce(public.compute_party_ar_balance(v_party_id), 0);
      exception when others then
        v_ar_balance := 0;
      end;
      
      if v_ar_balance > 0 then
        -- Deduct the lesser of: AR balance or (net_before_ar - minimum guarantee)
        -- Minimum guarantee: leave at least 30% of gross to avoid zero salary
        v_net_base := greatest(0, v_gross_base + v_allowances - (v_deductions + v_taxes));
        v_ar_deduction := least(v_ar_balance, greatest(0, v_net_base - round(v_gross_base * 0.30, 2)));
        v_ar_deduction := greatest(v_ar_deduction, 0);
        v_deductions := v_deductions + v_ar_deduction;
      end if;
    end if;

    v_net_base := greatest(0, v_gross_base + v_allowances - (v_deductions + v_taxes));

    update public.payroll_run_lines
    set basic_salary_base = v_basic_salary_base,
        prorated_salary = v_gross_base,
        absence_days = v_absence_days,
        absence_deduction = v_absence_deduction,
        overtime_hours = v_overtime_hours,
        overtime_addition = v_overtime_add,
        gross = v_gross_base,
        allowances = v_allowances,
        deductions = v_deductions + v_taxes,
        net = v_net_base,
        ar_deduction = v_ar_deduction,
        party_ar_balance = v_ar_balance
    where id = v_line.id;
  end loop;

  perform public.recalc_payroll_run_totals(p_run_id);
end;
$$;
revoke all on function public.compute_payroll_run_v4(uuid, boolean) from public;
grant execute on function public.compute_payroll_run_v4(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
