set app.allow_ledger_ddl = '1';

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
    where public.financial_parties.id = v_party_id;
  end if;
  
  return new;
end;
$$;

create or replace function public.ensure_financial_party_for_employee(p_employee_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party_id uuid;
  v_name text;
  v_currency text;
begin
  if p_employee_id is null then
    return null;
  end if;

  select fpl.party_id
  into v_party_id
  from public.financial_party_links fpl
  where fpl.linked_entity_type = 'payroll_employees'
    and fpl.linked_entity_id = p_employee_id::text
    and fpl.role = 'employee'
  limit 1;

  if v_party_id is not null then
    return v_party_id;
  end if;

  select
    coalesce(nullif(trim(e.full_name), ''), p_employee_id::text),
    nullif(trim(coalesce(e.currency, '')), '')
  into v_name, v_currency
  from public.payroll_employees e
  where e.id = p_employee_id;

  insert into public.financial_parties(name, party_type, linked_entity_type, linked_entity_id, currency_preference, created_by, updated_by)
  values (coalesce(v_name, p_employee_id::text), 'employee', 'payroll_employees', p_employee_id::text, v_currency, auth.uid(), auth.uid())
  returning public.financial_parties.id into v_party_id;

  insert into public.financial_party_links(party_id, role, linked_entity_type, linked_entity_id, created_by)
  values (v_party_id, 'employee', 'payroll_employees', p_employee_id::text, auth.uid())
  on conflict (linked_entity_type, linked_entity_id, role) do nothing;

  return v_party_id;
end;
$$;

notify pgrst, 'reload schema';
