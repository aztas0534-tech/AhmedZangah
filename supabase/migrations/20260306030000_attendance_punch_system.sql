-- ═══════════════════════════════════════════════════════════════
-- Employee Attendance Punch System
-- Fingerprint (WebAuthn) + PIN fallback
-- IP-restricted, audit-logged
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Add PIN and WebAuthn fields to payroll_employees ──
alter table public.payroll_employees
  add column if not exists pin text,
  add column if not exists webauthn_credential_id text,
  add column if not exists webauthn_public_key text;

-- PIN must be unique (4-digit)
create unique index if not exists idx_payroll_employees_pin
  on public.payroll_employees (pin)
  where pin is not null;

-- WebAuthn credential must be unique
create unique index if not exists idx_payroll_employees_webauthn
  on public.payroll_employees (webauthn_credential_id)
  where webauthn_credential_id is not null;

-- ── 2. Attendance config table ──
create table if not exists public.attendance_config (
  id uuid primary key default gen_random_uuid(),
  allowed_ips text[] not null default '{}',
  work_start_time time not null default '08:00',
  work_end_time time not null default '17:00',
  work_hours_per_day numeric not null default 8,
  late_threshold_minutes integer not null default 15,
  overtime_after_minutes integer not null default 0,
  overtime_rate_multiplier numeric not null default 1.5,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Insert default config if none exists
insert into public.attendance_config (id, allowed_ips)
values (gen_random_uuid(), '{}')
on conflict do nothing;

-- Ensure only one row
do $$ begin
  if (select count(*) from public.attendance_config) = 0 then
    insert into public.attendance_config (allowed_ips) values ('{}');
  end if;
end $$;

alter table public.attendance_config enable row level security;
create policy "attendance_config_read" on public.attendance_config for select to authenticated using (true);
create policy "attendance_config_write" on public.attendance_config for all to authenticated
  using (public.is_owner_or_manager()) with check (public.is_owner_or_manager());

-- ── 3. Attendance punches table ──
create table if not exists public.attendance_punches (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.payroll_employees(id) on delete cascade,
  punch_time timestamptz not null default now(),
  punch_type text not null check (punch_type in ('in', 'out')),
  ip_address text,
  device_info text,
  notes text,
  is_manual boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now()
);

create index if not exists idx_attendance_punches_employee_date
  on public.attendance_punches (employee_id, punch_time);

create index if not exists idx_attendance_punches_date
  on public.attendance_punches (punch_time);

alter table public.attendance_punches enable row level security;
create policy "attendance_punches_read" on public.attendance_punches for select to authenticated using (true);
create policy "attendance_punches_insert" on public.attendance_punches for insert to authenticated with check (true);
create policy "attendance_punches_delete" on public.attendance_punches for delete to authenticated
  using (public.is_owner_or_manager());

-- ── 4. RPC: Punch attendance (PIN method) ──
create or replace function public.punch_attendance_pin(
  p_pin text,
  p_type text,      -- 'in' or 'out'
  p_ip text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp record;
  v_config record;
  v_ip text;
  v_last_punch record;
  v_punch_id uuid;
begin
  -- Validate type
  if p_type not in ('in', 'out') then
    raise exception 'invalid punch type';
  end if;

  -- Validate PIN
  if p_pin is null or length(trim(p_pin)) < 3 then
    raise exception 'invalid PIN';
  end if;

  -- Find employee by PIN
  select id, full_name, employee_code, is_active
  into v_emp
  from public.payroll_employees
  where pin = trim(p_pin);

  if not found then
    raise exception 'PIN not found';
  end if;

  if not v_emp.is_active then
    raise exception 'employee is inactive';
  end if;

  -- Check IP restriction
  v_ip := coalesce(p_ip, '');
  select * into v_config from public.attendance_config limit 1;

  if v_config.allowed_ips is not null
     and array_length(v_config.allowed_ips, 1) > 0
     and v_ip <> '' then
    if not (v_ip = any(v_config.allowed_ips)) then
      raise exception 'punch not allowed from this location';
    end if;
  end if;

  -- Check last punch to prevent duplicate
  select * into v_last_punch
  from public.attendance_punches
  where employee_id = v_emp.id
  order by punch_time desc
  limit 1;

  if found and v_last_punch.punch_type = p_type
     and v_last_punch.punch_time > now() - interval '5 minutes' then
    raise exception 'duplicate punch within 5 minutes';
  end if;

  -- Record punch
  insert into public.attendance_punches (employee_id, punch_time, punch_type, ip_address, is_manual)
  values (v_emp.id, now(), p_type, v_ip, false)
  returning id into v_punch_id;

  return jsonb_build_object(
    'success', true,
    'punch_id', v_punch_id,
    'employee_name', v_emp.full_name,
    'employee_code', v_emp.employee_code,
    'punch_type', p_type,
    'punch_time', now()::text
  );
end;
$$;

-- ── 5. RPC: Punch attendance (WebAuthn method) ──
create or replace function public.punch_attendance_webauthn(
  p_credential_id text,
  p_type text,
  p_ip text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp record;
  v_config record;
  v_ip text;
  v_last_punch record;
  v_punch_id uuid;
begin
  if p_type not in ('in', 'out') then
    raise exception 'invalid punch type';
  end if;

  if p_credential_id is null or length(trim(p_credential_id)) < 5 then
    raise exception 'invalid credential';
  end if;

  -- Find employee by WebAuthn credential_id
  select id, full_name, employee_code, is_active
  into v_emp
  from public.payroll_employees
  where webauthn_credential_id = trim(p_credential_id);

  if not found then
    raise exception 'credential not registered';
  end if;

  if not v_emp.is_active then
    raise exception 'employee is inactive';
  end if;

  -- Check IP restriction
  v_ip := coalesce(p_ip, '');
  select * into v_config from public.attendance_config limit 1;

  if v_config.allowed_ips is not null
     and array_length(v_config.allowed_ips, 1) > 0
     and v_ip <> '' then
    if not (v_ip = any(v_config.allowed_ips)) then
      raise exception 'punch not allowed from this location';
    end if;
  end if;

  -- Check duplicate
  select * into v_last_punch
  from public.attendance_punches
  where employee_id = v_emp.id
  order by punch_time desc
  limit 1;

  if found and v_last_punch.punch_type = p_type
     and v_last_punch.punch_time > now() - interval '5 minutes' then
    raise exception 'duplicate punch within 5 minutes';
  end if;

  -- Record punch
  insert into public.attendance_punches (employee_id, punch_time, punch_type, ip_address, is_manual)
  values (v_emp.id, now(), p_type, v_ip, false)
  returning id into v_punch_id;

  return jsonb_build_object(
    'success', true,
    'punch_id', v_punch_id,
    'employee_name', v_emp.full_name,
    'employee_code', v_emp.employee_code,
    'punch_type', p_type,
    'punch_time', now()::text
  );
end;
$$;

-- ── 6. RPC: Manual punch by admin ──
create or replace function public.punch_attendance_manual(
  p_employee_id uuid,
  p_type text,
  p_time timestamptz,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_punch_id uuid;
begin
  if not public.is_owner_or_manager() then
    raise exception 'not allowed';
  end if;

  insert into public.attendance_punches (employee_id, punch_time, punch_type, notes, is_manual, created_by)
  values (p_employee_id, coalesce(p_time, now()), p_type, p_notes, true, auth.uid())
  returning id into v_punch_id;

  return v_punch_id;
end;
$$;

-- ── 7. RPC: Get daily summary from punches ──
create or replace function public.get_attendance_daily_summary(
  p_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_config record;
  v_result jsonb := '[]'::jsonb;
  v_emp record;
  v_first_in timestamptz;
  v_last_out timestamptz;
  v_hours numeric;
  v_status text;
  v_overtime numeric;
begin
  select * into v_config from public.attendance_config limit 1;

  for v_emp in
    select pe.id, pe.full_name, pe.employee_code
    from public.payroll_employees pe
    where pe.is_active = true
    order by pe.full_name
  loop
    -- First clock-in of the day
    select min(ap.punch_time)
    into v_first_in
    from public.attendance_punches ap
    where ap.employee_id = v_emp.id
      and ap.punch_type = 'in'
      and ap.punch_time::date = p_date;

    -- Last clock-out of the day
    select max(ap.punch_time)
    into v_last_out
    from public.attendance_punches ap
    where ap.employee_id = v_emp.id
      and ap.punch_type = 'out'
      and ap.punch_time::date = p_date;

    if v_first_in is null then
      v_hours := 0;
      v_status := 'absent';
      v_overtime := 0;
    else
      if v_last_out is not null and v_last_out > v_first_in then
        v_hours := round(extract(epoch from (v_last_out - v_first_in)) / 3600.0, 2);
      else
        v_hours := 0;
        v_status := 'incomplete';
      end if;

      if v_hours > 0 then
        -- Check if late
        if v_first_in::time > (v_config.work_start_time + (v_config.late_threshold_minutes || ' minutes')::interval) then
          v_status := 'late';
        else
          v_status := 'present';
        end if;

        -- Calculate overtime
        if v_hours > v_config.work_hours_per_day then
          v_overtime := round(v_hours - v_config.work_hours_per_day, 2);
        else
          v_overtime := 0;
        end if;
      end if;
    end if;

    v_result := v_result || jsonb_build_object(
      'employee_id', v_emp.id,
      'employee_name', v_emp.full_name,
      'employee_code', v_emp.employee_code,
      'date', p_date,
      'first_in', v_first_in,
      'last_out', v_last_out,
      'hours_worked', coalesce(v_hours, 0),
      'overtime_hours', coalesce(v_overtime, 0),
      'status', coalesce(v_status, 'absent')
    );
  end loop;

  return v_result;
end;
$$;

-- ── 8. RPC: Sync punches to payroll_attendance ──
create or replace function public.sync_punches_to_payroll_attendance(
  p_year integer,
  p_month integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_config record;
  v_start_date date;
  v_end_date date;
  v_day date;
  v_emp record;
  v_first_in timestamptz;
  v_last_out timestamptz;
  v_hours numeric;
  v_overtime numeric;
  v_absence numeric;
  v_count integer := 0;
begin
  if not public.is_owner_or_manager() then
    raise exception 'not allowed';
  end if;

  select * into v_config from public.attendance_config limit 1;
  v_start_date := make_date(p_year, p_month, 1);
  v_end_date := (v_start_date + interval '1 month' - interval '1 day')::date;

  for v_emp in select id from public.payroll_employees where is_active = true
  loop
    v_day := v_start_date;
    while v_day <= v_end_date loop
      -- Skip future dates
      if v_day > current_date then
        exit;
      end if;

      select min(ap.punch_time) into v_first_in
      from public.attendance_punches ap
      where ap.employee_id = v_emp.id and ap.punch_type = 'in' and ap.punch_time::date = v_day;

      select max(ap.punch_time) into v_last_out
      from public.attendance_punches ap
      where ap.employee_id = v_emp.id and ap.punch_type = 'out' and ap.punch_time::date = v_day;

      if v_first_in is null then
        v_hours := 0;
        v_absence := 1;
        v_overtime := 0;
      else
        if v_last_out is not null and v_last_out > v_first_in then
          v_hours := round(extract(epoch from (v_last_out - v_first_in)) / 3600.0, 2);
        else
          v_hours := 0;
        end if;
        v_absence := 0;
        if v_hours > v_config.work_hours_per_day then
          v_overtime := round(v_hours - v_config.work_hours_per_day, 2);
        else
          v_overtime := 0;
        end if;
      end if;

      insert into public.payroll_attendance (employee_id, work_date, hours_worked, overtime_hours, overtime_rate_multiplier, absence_days)
      values (v_emp.id, v_day, v_hours, v_overtime, v_config.overtime_rate_multiplier, v_absence)
      on conflict (employee_id, work_date) do update
        set hours_worked = excluded.hours_worked,
            overtime_hours = excluded.overtime_hours,
            overtime_rate_multiplier = excluded.overtime_rate_multiplier,
            absence_days = excluded.absence_days;

      v_count := v_count + 1;
      v_day := v_day + 1;
    end loop;
  end loop;

  return v_count;
end;
$$;

-- ── 9. RPC: Register WebAuthn credential for employee ──
create or replace function public.register_employee_webauthn(
  p_employee_id uuid,
  p_credential_id text,
  p_public_key text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_manager() then
    raise exception 'not allowed';
  end if;

  update public.payroll_employees
  set webauthn_credential_id = p_credential_id,
      webauthn_public_key = p_public_key
  where id = p_employee_id;

  if not found then
    raise exception 'employee not found';
  end if;
end;
$$;

-- ── 10. RPC: Get all WebAuthn credentials (for client-side lookup) ──
create or replace function public.get_attendance_webauthn_credentials()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return (
    select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    from (
      select pe.id as employee_id, pe.webauthn_credential_id as credential_id,
             pe.full_name, pe.employee_code
      from public.payroll_employees pe
      where pe.is_active = true
        and pe.webauthn_credential_id is not null
    ) t
  );
end;
$$;

-- Grant permissions
grant execute on function public.punch_attendance_pin(text, text, text) to authenticated;
grant execute on function public.punch_attendance_webauthn(text, text, text) to authenticated;
grant execute on function public.punch_attendance_manual(uuid, text, timestamptz, text) to authenticated;
grant execute on function public.get_attendance_daily_summary(date) to authenticated;
grant execute on function public.sync_punches_to_payroll_attendance(integer, integer) to authenticated;
grant execute on function public.register_employee_webauthn(uuid, text, text) to authenticated;
grant execute on function public.get_attendance_webauthn_credentials() to authenticated;

notify pgrst, 'reload schema';
