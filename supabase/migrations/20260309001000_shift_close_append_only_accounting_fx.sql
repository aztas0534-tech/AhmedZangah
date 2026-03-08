set app.allow_ledger_ddl = '1';

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

  v_cash := public.get_account_id_by_code('1010');
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
          v_entry_id,
          v_cash,
          0,
          v_total_base_diff,
          concat('Adjust cash (', v_curr, ') down'),
          case when v_curr <> v_base then v_curr else null end,
          case when v_curr <> v_base then abs(v_diff) else null end,
          case when v_curr <> v_base then v_fx_rate else null end
        );
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, currency_code, foreign_amount, fx_rate)
        values (
          v_entry_id,
          v_cash,
          v_total_base_diff,
          0,
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

notify pgrst, 'reload schema';
