create or replace function public.test_payroll_rls_error() returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  v_admin_id uuid;
  v_errs jsonb := '{}'::jsonb;
  v_err text;
begin
  SELECT auth_user_id INTO v_admin_id FROM public.admin_users WHERE is_active = true LIMIT 1;
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  begin
    perform id from public.payroll_employees limit 1;
  exception when others then
    v_errs := jsonb_set(v_errs, '{payroll_employees}', to_jsonb(sqlerrm));
  end;

  begin
    perform id from public.payroll_runs limit 1;
  exception when others then
    v_errs := jsonb_set(v_errs, '{payroll_runs}', to_jsonb(sqlerrm));
  end;

  begin
    perform id from public.cost_centers limit 1;
  exception when others then
    v_errs := jsonb_set(v_errs, '{cost_centers}', to_jsonb(sqlerrm));
  end;

  begin
    perform id from public.payroll_settings limit 1;
  exception when others then
    v_errs := jsonb_set(v_errs, '{payroll_settings}', to_jsonb(sqlerrm));
  end;

   begin
    perform id from public.financial_parties limit 1;
  exception when others then
    v_errs := jsonb_set(v_errs, '{financial_parties}', to_jsonb(sqlerrm));
  end;

  return v_errs;
end;
$$;
