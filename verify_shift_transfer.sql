-- Test script to verify the shift cash transfer functionality
do $$
declare
  v_shift_id uuid;
  v_bank_account_id uuid;
  v_admin_id uuid;
begin
  select id into v_shift_id from public.cash_shifts where status = 'open' limit 1;
  select id into v_bank_account_id from public.chart_of_accounts where code = '1020002' and is_active = true limit 1;
  select auth_user_id into v_admin_id from public.admin_users where role = 'owner' limit 1;

  if v_shift_id is null or v_bank_account_id is null or v_admin_id is null then
    raise notice 'missing prerequisites for test';
    return;
  end if;

  -- Impersonate admin for RLS
  perform set_config('request.jwt.claim.sub', v_admin_id::text, true);

  -- Perform transfer from shift to bank
  raise notice 'Executing record_shift_cash_movement for Shift % to Bank %', v_shift_id, v_bank_account_id;
  
  perform public.record_shift_cash_movement(
    p_shift_id := v_shift_id,
    p_direction := 'out',
    p_amount := 50.00,
    p_reason := 'Transfer to Bank Test',
    p_occurred_at := now(),
    p_destination_account_id := v_bank_account_id
  );
  
  raise notice 'Test completed successfully';
end;
$$;
