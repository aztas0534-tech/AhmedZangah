-- =======================================================================
-- Cashier Sub-Accounts + Shift Approval Workflow
-- 
-- 1) Add review/approval columns to cash_shifts (nullable, safe)
-- 2) Add cash_account_id FK to cash_shifts (nullable, safe)
-- 3) Create ensure_cashier_cash_account() to auto-provision GL sub-accounts
-- 4) Update post_cash_shift_close to use per-cashier account
-- 5) Create review_cash_shift() for approval workflow
-- =======================================================================

set app.allow_ledger_ddl = '1';

-- ─── 1. New columns on cash_shifts ──────────────────────────────────────
alter table public.cash_shifts
  add column if not exists review_status text check (review_status in ('pending','approved','rejected')),
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists cash_account_id uuid references public.chart_of_accounts(id);

create index if not exists idx_cash_shifts_review_status on public.cash_shifts(review_status);

-- ─── 2. Auto-provision cashier sub-account under 1010 ───────────────────
create or replace function public.ensure_cashier_cash_account(p_cashier_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account_id uuid;
  v_cashier_name text;
  v_next_code text;
  v_seq int;
begin
  -- Check if cashier already has a dedicated account
  select cs.cash_account_id
  into v_account_id
  from public.cash_shifts cs
  where cs.cashier_id = p_cashier_id
    and cs.cash_account_id is not null
  order by cs.opened_at desc
  limit 1;

  if v_account_id is not null then
    -- Verify account still exists
    if exists (select 1 from public.chart_of_accounts where id = v_account_id and is_active = true) then
      return v_account_id;
    end if;
  end if;

  -- Get cashier display name
  select coalesce(nullif(trim(au.full_name), ''), nullif(trim(au.username), ''), 'Cashier')
  into v_cashier_name
  from public.admin_users au
  where au.auth_user_id = p_cashier_id
  limit 1;

  if v_cashier_name is null then
    v_cashier_name := 'Cashier';
  end if;

  -- Find existing account for this cashier by name pattern
  select coa.id
  into v_account_id
  from public.chart_of_accounts coa
  where coa.code like '1010-%'
    and coa.is_active = true
    and coa.name ilike '%' || v_cashier_name || '%'
  limit 1;

  if v_account_id is not null then
    return v_account_id;
  end if;

  -- Generate next sequential sub-code
  select coalesce(max(
    case when coa.code ~ '^1010-\d+$'
      then substring(coa.code from 6)::int
      else 0
    end
  ), 0) + 1
  into v_seq
  from public.chart_of_accounts coa
  where coa.code like '1010-%';

  v_next_code := '1010-' || lpad(v_seq::text, 2, '0');

  -- Create the sub-account
  insert into public.chart_of_accounts(code, name, account_type, normal_balance)
  values (v_next_code, 'Cash - ' || v_cashier_name, 'asset', 'debit')
  on conflict (code) do update
    set name = excluded.name, is_active = true
  returning id into v_account_id;

  return v_account_id;
end;
$$;

revoke all on function public.ensure_cashier_cash_account(uuid) from public;
grant execute on function public.ensure_cashier_cash_account(uuid) to authenticated;


-- ─── 3. Updated post_cash_shift_close to use cashier sub-account ────────
create or replace function public.post_cash_shift_close(p_shift_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift record;
  v_existing_entry_id uuid;
  v_entry_id uuid;
  v_cash uuid;
  v_over_short uuid;
  v_base text;
  v_curr text;
  v_diff numeric;
  v_total_base_diff numeric;
  v_fx_rate numeric;
  v_line_added boolean := false;
begin
  if p_shift_id is null then
    raise exception 'p_shift_id is required';
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
    return;
  end if;

  select je.id
  into v_existing_entry_id
  from public.journal_entries je
  where je.source_table = 'cash_shifts'
    and je.source_id = p_shift_id::text
    and je.source_event = 'closed'
  order by je.entry_date desc, je.id desc
  limit 1;

  if v_existing_entry_id is not null then
    return;
  end if;

  -- Use cashier sub-account if available, otherwise fallback to 1010
  v_cash := coalesce(
    v_shift.cash_account_id,
    public.get_account_id_by_code('1010')
  );
  v_over_short := public.get_account_id_by_code('6110');
  if v_cash is null or v_over_short is null then
    raise exception 'required shift close accounts not found';
  end if;

  v_base := upper(coalesce(public.get_base_currency(), 'YER'));

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (
    coalesce(v_shift.closed_at, now()),
    concat('Cash shift close ', p_shift_id::text),
    'cash_shifts',
    p_shift_id::text,
    'closed',
    auth.uid(),
    'posted'
  )
  returning id into v_entry_id;

  if v_shift.difference_json is not null and (select count(*) from jsonb_object_keys(v_shift.difference_json)) > 0 then
    for v_curr, v_diff in
      select upper(key), value::text::numeric
      from jsonb_each(v_shift.difference_json)
    loop
      if abs(v_diff) <= 1e-9 then
        continue;
      end if;

      v_line_added := true;
      if v_curr = v_base then
        v_fx_rate := 1;
      else
        v_fx_rate := public.get_fx_rate(v_curr, coalesce(v_shift.closed_at, now())::date, 'accounting');
        if v_fx_rate is null or v_fx_rate <= 0 then
          raise exception 'accounting fx rate missing for % at %', v_curr, coalesce(v_shift.closed_at, now())::date;
        end if;
      end if;

      v_total_base_diff := abs(v_diff) * v_fx_rate;

      if v_diff < 0 then
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
        values (v_entry_id, v_over_short, v_total_base_diff, 0, concat('Cash shortage (', v_curr, ')'));

        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, foreign_amount, fx_rate)
        values (
          v_entry_id, v_cash, 0, v_total_base_diff,
          concat('Adjust cash (', v_curr, ') down'),
          case when v_curr <> v_base then v_curr else null end,
          case when v_curr <> v_base then abs(v_diff) else null end,
          case when v_curr <> v_base then v_fx_rate else null end
        );
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, foreign_amount, fx_rate)
        values (
          v_entry_id, v_cash, v_total_base_diff, 0,
          concat('Adjust cash (', v_curr, ') up'),
          case when v_curr <> v_base then v_curr else null end,
          case when v_curr <> v_base then abs(v_diff) else null end,
          case when v_curr <> v_base then v_fx_rate else null end
        );

        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
        values (v_entry_id, v_over_short, 0, v_total_base_diff, concat('Cash overage (', v_curr, ')'));
      end if;
    end loop;
  else
    v_diff := coalesce(v_shift.difference, coalesce(v_shift.end_amount, 0) - coalesce(v_shift.expected_amount, 0));
    if abs(v_diff) > 1e-9 then
      v_line_added := true;
      if v_diff < 0 then
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
        values
          (v_entry_id, v_over_short, abs(v_diff), 0, 'Cash shortage'),
          (v_entry_id, v_cash, 0, abs(v_diff), 'Adjust cash to counted');
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
        values
          (v_entry_id, v_cash, v_diff, 0, 'Adjust cash to counted'),
          (v_entry_id, v_over_short, 0, v_diff, 'Cash overage');
      end if;
    end if;
  end if;

  if not v_line_added then
    delete from public.journal_entries where id = v_entry_id;
    return;
  end if;

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;


-- ─── 4. Auto-assign sub-account on shift open ───────────────────────────
create or replace function public.trg_assign_cashier_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.cash_account_id is null and new.cashier_id is not null then
    begin
      new.cash_account_id := public.ensure_cashier_cash_account(new.cashier_id);
    exception when others then
      -- Silently skip if account creation fails; fallback to 1010
      null;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_cash_shifts_assign_account on public.cash_shifts;
create trigger trg_cash_shifts_assign_account
  before insert on public.cash_shifts
  for each row
  execute function public.trg_assign_cashier_account();


-- ─── 5. Review/Approve cash shift function ──────────────────────────────
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

  -- Check permissions
  select au.role
  into v_actor_role
  from public.admin_users au
  where au.auth_user_id = auth.uid()
    and au.is_active = true;

  if v_actor_role is null or (
    v_actor_role not in ('owner', 'manager')
    and not public.has_admin_permission('cashShifts.manage')
    and not public.has_admin_permission('accounting.view')
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

revoke all on function public.review_cash_shift(uuid, text, text) from public;
grant execute on function public.review_cash_shift(uuid, text, text) to authenticated;


-- ─── 6. Reconciliation Summary RPC ──────────────────────────────────────
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

  -- Aggregate shift stats
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

  -- By cashier breakdown
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

  -- By currency (from difference_json)
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

  -- By payment method
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

revoke all on function public.get_shift_reconciliation_summary(timestamptz, timestamptz, uuid) from public;
grant execute on function public.get_shift_reconciliation_summary(timestamptz, timestamptz, uuid) to authenticated;

notify pgrst, 'reload schema';
