-- Fix get_active_fx_rate nonexistent function typo in post_cash_shift_close

set app.allow_ledger_ddl = '1';

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
      
      -- Fetch active fx rate or fallback to 1
      select current_exchange_rate into v_base_rate from public.currencies where code = v_curr;
      if v_base_rate is null then
        v_base_rate := 1;
      end if;

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
