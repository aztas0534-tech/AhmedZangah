do $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into public.payroll_employees (id, full_name, is_active, monthly_salary, currency)
  values (v_id, 'Test Employee', true, 1000, 'YER');
end $$;
