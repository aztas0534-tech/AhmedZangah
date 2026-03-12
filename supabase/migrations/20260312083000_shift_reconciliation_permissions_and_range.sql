create or replace function public.review_cash_shift(
  p_shift_id uuid,
  p_status text,
  p_notes text default null
)
returns public.cash_shifts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift public.cash_shifts%rowtype;
  v_actor_role text;
begin
  if auth.uid() is null then
    raise exception 'not allowed';
  end if;

  if p_shift_id is null then
    raise exception 'p_shift_id is required';
  end if;

  if p_status not in ('approved', 'rejected', 'pending') then
    raise exception 'invalid review status: %', p_status;
  end if;

  if p_status = 'rejected' and nullif(trim(coalesce(p_notes, '')), '') is null then
    raise exception 'ملاحظة الرفض مطلوبة';
  end if;

  select au.role
  into v_actor_role
  from public.admin_users au
  where au.auth_user_id = auth.uid()
    and au.is_active = true;

  if v_actor_role is null or (
    v_actor_role not in ('owner', 'manager')
    and not public.has_admin_permission('cashShifts.manage')
  ) then
    raise exception 'ليس لديك صلاحية مراجعة الورديات';
  end if;

  select *
  into v_shift
  from public.cash_shifts s
  where s.id = p_shift_id
  for update;

  if not found then
    raise exception 'cash shift not found';
  end if;

  if coalesce(v_shift.status, 'open') <> 'closed' then
    raise exception 'لا يمكن مراجعة وردية مفتوحة — يجب إغلاقها أولاً';
  end if;

  update public.cash_shifts
  set
    review_status = p_status,
    reviewed_at = now(),
    reviewed_by = auth.uid(),
    notes = case
      when p_notes is not null and trim(p_notes) <> ''
        then coalesce(notes, '') || E'\n[مراجعة: ' || p_status || '] ' || trim(p_notes)
      else notes
    end
  where id = p_shift_id
  returning * into v_shift;

  return v_shift;
end;
$$;

create or replace function public.get_shift_reconciliation_summary(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_cashier_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_by_cashier jsonb;
  v_by_currency jsonb;
  v_by_method jsonb;
  v_shifts_total int;
  v_shifts_open int;
  v_shifts_closed int;
  v_shifts_approved int;
  v_shifts_pending int;
  v_shifts_rejected int;
  v_total_start numeric;
  v_total_expected numeric;
  v_total_counted numeric;
  v_total_difference numeric;
  v_actor_role text;
begin
  if auth.uid() is null then
    raise exception 'not allowed';
  end if;

  if p_start_date is null or p_end_date is null then
    raise exception 'start/end date are required';
  end if;
  if p_start_date > p_end_date then
    raise exception 'invalid date range';
  end if;

  select au.role into v_actor_role
  from public.admin_users au
  where au.auth_user_id = auth.uid() and au.is_active = true;

  if v_actor_role is null or (
    v_actor_role not in ('owner', 'manager')
    and not public.has_admin_permission('cashShifts.manage')
    and not public.has_admin_permission('accounting.view')
  ) then
    raise exception 'ليس لديك صلاحية عرض تقارير المطابقة';
  end if;

  select
    count(*)::int,
    count(*) filter (where s.status = 'open')::int,
    count(*) filter (where s.status = 'closed')::int,
    count(*) filter (where s.review_status = 'approved')::int,
    count(*) filter (where s.status = 'closed' and coalesce(s.review_status, 'pending') = 'pending')::int,
    count(*) filter (where s.review_status = 'rejected')::int,
    coalesce(sum(coalesce(s.start_amount, 0)), 0),
    coalesce(sum(coalesce(s.expected_amount, 0)), 0),
    coalesce(sum(coalesce(s.end_amount, 0)) filter (where s.status = 'closed'), 0),
    coalesce(sum(coalesce(s.difference, 0)) filter (where s.status = 'closed'), 0)
  into
    v_shifts_total, v_shifts_open, v_shifts_closed,
    v_shifts_approved, v_shifts_pending, v_shifts_rejected,
    v_total_start, v_total_expected, v_total_counted, v_total_difference
  from public.cash_shifts s
  where s.opened_at >= p_start_date
    and s.opened_at <= p_end_date
    and (p_cashier_id is null or s.cashier_id = p_cashier_id);

  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb)
  into v_by_cashier
  from (
    select
      s.cashier_id,
      coalesce(au.full_name, au.username, 'Unknown') as cashier_name,
      count(*)::int as shift_count,
      count(*) filter (where s.status = 'closed')::int as closed_count,
      count(*) filter (where s.review_status = 'approved')::int as approved_count,
      count(*) filter (where s.status = 'closed' and coalesce(s.review_status, 'pending') = 'pending')::int as pending_count,
      coalesce(sum(coalesce(s.start_amount, 0)), 0) as total_start,
      coalesce(sum(coalesce(s.expected_amount, 0)) filter (where s.status = 'closed'), 0) as total_expected,
      coalesce(sum(coalesce(s.end_amount, 0)) filter (where s.status = 'closed'), 0) as total_counted,
      coalesce(sum(coalesce(s.difference, 0)) filter (where s.status = 'closed'), 0) as total_difference
    from public.cash_shifts s
    left join public.admin_users au on au.auth_user_id = s.cashier_id
    where s.opened_at >= p_start_date
      and s.opened_at <= p_end_date
      and (p_cashier_id is null or s.cashier_id = p_cashier_id)
    group by s.cashier_id, au.full_name, au.username
    order by total_difference asc
  ) x;

  select coalesce(jsonb_object_agg(cur, jsonb_build_object(
    'total_difference', total_diff
  )), '{}'::jsonb)
  into v_by_currency
  from (
    select
      upper(kv.key) as cur,
      sum(kv.value::text::numeric) as total_diff
    from public.cash_shifts s,
      lateral jsonb_each(coalesce(s.difference_json, '{}'::jsonb)) kv
    where s.opened_at >= p_start_date
      and s.opened_at <= p_end_date
      and s.status = 'closed'
      and (p_cashier_id is null or s.cashier_id = p_cashier_id)
    group by upper(kv.key)
  ) sq;

  select coalesce(jsonb_object_agg(method, jsonb_build_object('in', total_in, 'out', total_out)), '{}'::jsonb)
  into v_by_method
  from (
    select
      p.method,
      coalesce(sum(case when p.direction = 'in' then coalesce(p.base_amount, p.amount) else 0 end), 0) as total_in,
      coalesce(sum(case when p.direction = 'out' then coalesce(p.base_amount, p.amount) else 0 end), 0) as total_out
    from public.payments p
    join public.cash_shifts s on s.id = p.shift_id
    where s.opened_at >= p_start_date
      and s.opened_at <= p_end_date
      and (p_cashier_id is null or s.cashier_id = p_cashier_id)
    group by p.method
  ) sq;

  v_result := jsonb_build_object(
    'period', jsonb_build_object('start', p_start_date, 'end', p_end_date),
    'shifts_total', v_shifts_total,
    'shifts_open', v_shifts_open,
    'shifts_closed', v_shifts_closed,
    'shifts_approved', v_shifts_approved,
    'shifts_pending', v_shifts_pending,
    'shifts_rejected', v_shifts_rejected,
    'total_start_amount', v_total_start,
    'total_expected', v_total_expected,
    'total_counted', v_total_counted,
    'total_difference', v_total_difference,
    'by_cashier', v_by_cashier,
    'by_currency', v_by_currency,
    'by_method', v_by_method
  );

  return v_result;
end;
$$;

revoke all on function public.review_cash_shift(uuid, text, text) from public;
grant execute on function public.review_cash_shift(uuid, text, text) to authenticated;
revoke all on function public.get_shift_reconciliation_summary(timestamptz, timestamptz, uuid) from public;
grant execute on function public.get_shift_reconciliation_summary(timestamptz, timestamptz, uuid) to authenticated;

notify pgrst, 'reload schema';
