-- Migration to support True Multi-Currency Shifts

set app.allow_ledger_ddl = '1';

alter table public.cash_shifts
add column if not exists difference_json jsonb;

-- New function to calculate expected cash per currency
create or replace function public.calculate_cash_shift_expected_multicurrency(p_shift_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift record;
  v_base text;
  v_result jsonb := '{}'::jsonb;
  v_currency text;
  v_in numeric;
  v_out numeric;
begin
  if p_shift_id is null then
    raise exception 'p_shift_id is required';
  end if;

  v_base := public.get_base_currency();

  select *
  into v_shift
  from public.cash_shifts s
  where s.id = p_shift_id;

  if not found then
    raise exception 'cash shift not found';
  end if;

  if coalesce(v_shift.start_amount, 0) > 0 then
    v_result := jsonb_set(
      v_result, 
      array[v_base], 
      to_jsonb(coalesce(v_shift.start_amount, 0))
    );
  end if;

  for v_currency, v_in, v_out in
    select 
      upper(coalesce(nullif(trim(p.currency), ''), v_base)),
      coalesce(sum(case when p.direction = 'in' then p.amount else 0 end), 0),
      coalesce(sum(case when p.direction = 'out' then p.amount else 0 end), 0)
    from public.payments p
    where p.method = 'cash'
      and (
        p.shift_id = p_shift_id
        or (
          p.shift_id is null
          and p.created_by = v_shift.cashier_id
          and p.occurred_at >= coalesce(v_shift.opened_at, now())
          and p.occurred_at <= coalesce(v_shift.closed_at, now())
        )
      )
    group by upper(coalesce(nullif(trim(p.currency), ''), v_base))
  loop
    v_result := jsonb_set(
      v_result, 
      array[v_currency], 
      to_jsonb(
        coalesce((v_result->>v_currency)::numeric, 0) + v_in - v_out
      )
    );
  end loop;

  return v_result;
end;
$$;

revoke all on function public.calculate_cash_shift_expected_multicurrency(uuid) from public;
grant execute on function public.calculate_cash_shift_expected_multicurrency(uuid) to anon, authenticated;


-- New v3 function to close shift with multicurrency tender counts
create or replace function public.close_cash_shift_v3(
  p_shift_id uuid,
  p_end_amount numeric,
  p_notes text default null,
  p_forced_reason text default null,
  p_denomination_counts jsonb default null,
  p_tender_counts jsonb default null
)
returns public.cash_shifts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift public.cash_shifts%rowtype;
  v_expected_overall numeric;
  v_expected_json jsonb;
  v_diff_json jsonb := '{}'::jsonb;
  v_curr text;
  v_expected_amt numeric;
  v_counted_amt numeric;
  v_actor_role text;
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

  if auth.uid() <> v_shift.cashier_id and (v_actor_role not in ('owner', 'manager') and not public.has_admin_permission('cashShifts.manage')) then
    raise exception 'not allowed';
  end if;

  if coalesce(v_shift.status, 'open') <> 'open' then
    return v_shift;
  end if;

  if coalesce(p_end_amount, 0) < 0 then
    raise exception 'invalid end amount';
  end if;

  v_expected_overall := public.calculate_cash_shift_expected(p_shift_id);
  v_expected_json := public.calculate_cash_shift_expected_multicurrency(p_shift_id);

  -- Calculate multicurrency differences
  if p_tender_counts is not null and p_tender_counts->'cash' is not null then
    -- Both expected and counted have keys for currencies
    
    -- 1. Loop through all expected currencies
    for v_curr, v_expected_amt in select key, value::text::numeric from jsonb_each(v_expected_json) loop
      v_counted_amt := coalesce((p_tender_counts->'cash'->>v_curr)::numeric, 0);
      if abs(v_counted_amt - v_expected_amt) > 0.0001 then
        v_diff_json := jsonb_set(v_diff_json, array[v_curr], to_jsonb(v_counted_amt - v_expected_amt));
      end if;
    end loop;
    
    -- 2. Loop through all counted currencies to catch unexpected overages (not in expected json)
    for v_curr, v_counted_amt in select key, value::text::numeric from jsonb_each(p_tender_counts->'cash') loop
      if not (v_expected_json ? v_curr) then
        if v_counted_amt > 0.0001 then
          v_diff_json := jsonb_set(v_diff_json, array[v_curr], to_jsonb(v_counted_amt));
        end if;
      end if;
    end loop;
  end if;

  update public.cash_shifts
  set closed_at = now(),
      end_amount = coalesce(p_end_amount, 0),
      expected_amount = v_expected_overall,
      difference = coalesce(p_end_amount, 0) - coalesce(v_expected_overall, 0),
      difference_json = v_diff_json,
      status = 'closed',
      notes = nullif(coalesce(p_notes, ''), ''),
      forced_close = case when p_forced_reason is not null then true else false end,
      forced_close_reason = p_forced_reason,
      denomination_counts = p_denomination_counts,
      tender_counts = p_tender_counts
  where id = p_shift_id
  returning * into v_shift;

  perform public.post_cash_shift_close(p_shift_id);

  return v_shift;
end;
$$;

revoke all on function public.close_cash_shift_v3(uuid, numeric, text, text, jsonb, jsonb) from public;
grant execute on function public.close_cash_shift_v3(uuid, numeric, text, text, jsonb, jsonb) to anon, authenticated;


-- Modify post_cash_shift_close to post differences per currency
create or replace function public.post_cash_shift_close(p_shift_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift record;
  v_entry_id uuid;
  v_cash uuid;
  v_over_short uuid;
  v_base text;
  v_curr text;
  v_diff numeric;
  v_total_base_diff numeric;
  v_base_rate numeric;
  v_line_added boolean := false;
begin
  if p_shift_id is null then
    raise exception 'p_shift_id is required';
  end if;
  
  select *
  into v_shift
  from public.cash_shifts s
  where s.id = p_shift_id;
  
  if not found then
    raise exception 'cash shift not found';
  end if;
  
  if coalesce(v_shift.status, 'open') <> 'closed' then
    return;
  end if;
  
  v_cash := public.get_account_id_by_code('1010');
  v_over_short := public.get_account_id_by_code('6110');
  
  -- Create journal entry
  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
  values (
    coalesce(v_shift.closed_at, now()),
    concat('Cash shift close ', v_shift.id::text),
    'cash_shifts',
    v_shift.id::text,
    'closed',
    auth.uid()
  )
  on conflict (source_table, source_id, source_event)
  do update set entry_date = excluded.entry_date, memo = excluded.memo
  returning id into v_entry_id;
  
  delete from public.journal_lines jl where jl.journal_entry_id = v_entry_id;
  
  v_base := public.get_base_currency();

  -- If difference_json is present and has keys, use multi-currency logic
  if v_shift.difference_json is not null and (select count(*) from jsonb_object_keys(v_shift.difference_json)) > 0 then
    
    for v_curr, v_diff in select key, value::text::numeric from jsonb_each(v_shift.difference_json) loop
      if abs(v_diff) <= 1e-9 then
        continue;
      end if;

      v_line_added := true;
      v_base_rate := public.get_active_fx_rate(v_curr);
      v_total_base_diff := v_diff * v_base_rate;

      if v_diff < 0 then
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, foreign_amount, fx_rate)
        values
          (v_entry_id, v_over_short, abs(v_total_base_diff), 0, concat('Cash shortage (', v_curr, ')'), null, null, null),
          (v_entry_id, v_cash, 0, abs(v_total_base_diff), concat('Adjust cash (', v_curr, ') down'), case when v_curr <> v_base then v_curr else null end, case when v_curr <> v_base then abs(v_diff) else null end, case when v_curr <> v_base then v_base_rate else null end);
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, foreign_amount, fx_rate)
        values
          (v_entry_id, v_cash, v_total_base_diff, 0, concat('Adjust cash (', v_curr, ') up'), case when v_curr <> v_base then v_curr else null end, case when v_curr <> v_base then abs(v_diff) else null end, case when v_curr <> v_base then v_base_rate else null end),
          (v_entry_id, v_over_short, 0, v_total_base_diff, concat('Cash overage (', v_curr, ')'), null, null, null);
      end if;
    end loop;
    
  else
    -- Fallback to single base currency difference
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

  -- Cleanup empty journals
  if not v_line_added then
    delete from public.journal_entries where id = v_entry_id;
  end if;

end;
$$;

revoke all on function public.post_cash_shift_close(uuid) from public;
grant execute on function public.post_cash_shift_close(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
