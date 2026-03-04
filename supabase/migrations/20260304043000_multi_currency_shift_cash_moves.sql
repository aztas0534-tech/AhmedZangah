-- =============================================================================
-- ميزة الصرف والإيداع متعدد العملات في الورديات
-- =============================================================================

create or replace function public.record_shift_cash_movement(
  p_shift_id uuid,
  p_direction text,
  p_amount numeric,
  p_reason text default null,
  p_occurred_at timestamptz default null,
  p_destination_account_id uuid default null,
  p_currency text default null,
  p_fx_rate numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift public.cash_shifts%rowtype;
  v_amount numeric;
  v_dir text;
  v_actor_role text;
  v_payment_id uuid;
  v_payment_data jsonb;
  v_base_currency text;
  v_currency text;
  v_fx_rate numeric;
  v_base_amount numeric;
begin
  if auth.uid() is null then
    raise exception 'not allowed';
  end if;

  if p_shift_id is null then
    raise exception 'p_shift_id is required';
  end if;

  select au.role
  into v_actor_role
  from public.admin_users au
  where au.auth_user_id = auth.uid()
    and au.is_active = true;

  if v_actor_role is null then
    raise exception 'not allowed';
  end if;

  select *
  into v_shift
  from public.cash_shifts s
  where s.id = p_shift_id
  for update;

  if not found then
    raise exception 'cash shift not found';
  end if;

  if coalesce(v_shift.status, 'open') <> 'open' then
    raise exception 'cash shift is not open';
  end if;

  if auth.uid() <> v_shift.cashier_id and (v_actor_role not in ('owner', 'manager') and not public.has_admin_permission('cashShifts.manage')) then
    raise exception 'not allowed';
  end if;

  v_dir := lower(nullif(trim(coalesce(p_direction, '')), ''));
  if v_dir not in ('in', 'out') then
    raise exception 'invalid direction';
  end if;

  v_amount := coalesce(p_amount, 0);
  if v_amount <= 0 then
    raise exception 'invalid amount';
  end if;
  
  if p_destination_account_id is not null then
    if not exists (select 1 from public.chart_of_accounts where id = p_destination_account_id and is_active = true) then
      raise exception 'invalid destination account';
    end if;
  end if;

  -- حسابات العملة
  v_base_currency := public.get_base_currency();
  v_currency := upper(nullif(trim(coalesce(p_currency, v_base_currency)), ''));
  v_fx_rate := coalesce(p_fx_rate, 1);
  if v_fx_rate <= 0 then
    raise exception 'invalid fx rate';
  end if;
  
  v_base_amount := v_amount;
  if v_currency <> v_base_currency then
    v_base_amount := round(v_amount * v_fx_rate, 2);
  end if;

  v_payment_data := jsonb_build_object(
    'shiftId', p_shift_id::text, 
    'reason', nullif(trim(coalesce(p_reason, '')), ''), 
    'kind', 'cash_movement'
  );
  
  if p_destination_account_id is not null then
    v_payment_data := v_payment_data || jsonb_build_object('overrideAccountId', p_destination_account_id::text);
  end if;

  insert into public.payments(
    direction, method, amount, currency, fx_rate, base_amount, 
    reference_table, reference_id, occurred_at, created_by, data, shift_id
  )
  values (
    v_dir,
    'cash',
    v_amount,
    v_currency,
    v_fx_rate,
    v_base_amount,
    'cash_shifts',
    p_shift_id::text,
    coalesce(p_occurred_at, now()),
    auth.uid(),
    jsonb_strip_nulls(v_payment_data),
    p_shift_id
  )
  returning id into v_payment_id;

  perform public.post_payment(v_payment_id);

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    case when v_dir = 'in' then 'cash_shift_cash_in' else 'cash_shift_cash_out' end,
    'cash_shifts',
    case when v_dir = 'in' then 'Cash movement in' else 'Cash movement out' end,
    auth.uid(),
    now(),
    jsonb_strip_nulls(jsonb_build_object(
      'shiftId', p_shift_id::text, 
      'paymentId', v_payment_id::text, 
      'amount', v_amount, 
      'currency', v_currency,
      'fx_rate', v_fx_rate,
      'base_amount', v_base_amount,
      'direction', v_dir, 
      'reason', nullif(trim(coalesce(p_reason, '')), ''), 
      'destinationAccountId', p_destination_account_id::text
    )),
    'MEDIUM',
    'SHIFT_CASH_MOVE'
  );
end;
$$;

revoke all on function public.record_shift_cash_movement(uuid, text, numeric, text, timestamptz, uuid, text, numeric) from public;
grant execute on function public.record_shift_cash_movement(uuid, text, numeric, text, timestamptz, uuid, text, numeric) to anon, authenticated;

-- Overload for compatibility
create or replace function public.record_shift_cash_movement(
  p_shift_id uuid,
  p_direction text,
  p_amount numeric,
  p_reason text default null,
  p_occurred_at timestamptz default null,
  p_destination_account_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.record_shift_cash_movement(p_shift_id, p_direction, p_amount, p_reason, p_occurred_at, p_destination_account_id, null, null);
end;
$$;

revoke all on function public.record_shift_cash_movement(uuid, text, numeric, text, timestamptz, uuid) from public;
grant execute on function public.record_shift_cash_movement(uuid, text, numeric, text, timestamptz, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
