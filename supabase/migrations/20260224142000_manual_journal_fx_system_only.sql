set app.allow_ledger_ddl = '1';

create or replace function public.create_manual_journal_entry(
  p_entry_date timestamptz,
  p_memo text,
  p_lines jsonb,
  p_journal_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_id uuid;
  v_line jsonb;
  v_account_code text;
  v_account_id uuid;
  v_debit numeric;
  v_credit numeric;
  v_memo text;
  v_cost_center_id uuid;
  v_journal_id uuid;
  v_party_id uuid;
  v_currency_code text;
  v_fx_rate numeric;
  v_foreign_amount numeric;
  v_entry_date timestamptz;
  v_base text := public.get_base_currency();
  v_base_amount numeric;
begin
  if not public.is_owner_or_manager() then
    raise exception 'not allowed';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'p_lines must be a json array';
  end if;

  v_entry_date := coalesce(p_entry_date, now());
  v_memo := nullif(trim(coalesce(p_memo, '')), '');
  v_journal_id := coalesce(p_journal_id, public.get_default_journal_id(), '00000000-0000-4000-8000-000000000001'::uuid);

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, journal_id)
  values (
    v_entry_date,
    v_memo,
    'manual',
    null,
    null,
    auth.uid(),
    v_journal_id
  )
  returning id into v_entry_id;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_account_code := nullif(trim(coalesce(v_line->>'accountCode', '')), '');
    v_debit := coalesce(nullif(v_line->>'debit', '')::numeric, 0);
    v_credit := coalesce(nullif(v_line->>'credit', '')::numeric, 0);
    v_cost_center_id := nullif(v_line->>'costCenterId', '')::uuid;
    v_party_id := nullif(v_line->>'partyId', '')::uuid;
    v_currency_code := upper(nullif(trim(coalesce(v_line->>'currencyCode','')), ''));
    v_fx_rate := null;
    v_foreign_amount := null;
    begin
      v_foreign_amount := nullif(v_line->>'foreignAmount', '')::numeric;
    exception when others then
      v_foreign_amount := null;
    end;

    if v_account_code is null then
      raise exception 'accountCode is required';
    end if;

    select id into v_account_id
    from public.chart_of_accounts
    where code = v_account_code
      and is_active = true
    limit 1;
    if v_account_id is null then
      raise exception 'account not found: %', v_account_code;
    end if;

    if (v_debit > 0 and v_credit > 0) or (v_debit = 0 and v_credit = 0) then
      raise exception 'either debit or credit must be > 0';
    end if;

    if v_currency_code is not null then
      if not exists (select 1 from public.currencies c where upper(c.code) = v_currency_code limit 1) then
        raise exception 'unsupported currency: %', v_currency_code;
      end if;
      if upper(v_currency_code) = upper(v_base) then
        v_currency_code := null;
        v_fx_rate := null;
        v_foreign_amount := null;
      end if;
    end if;

    if v_currency_code is not null and upper(v_currency_code) <> upper(v_base) then
      v_fx_rate := public.get_fx_rate(v_currency_code, v_entry_date::date, 'accounting');
      if v_fx_rate is null or v_fx_rate <= 0 then
        raise exception 'accounting fx rate missing for currency % at %', v_currency_code, v_entry_date::date;
      end if;
      if v_foreign_amount is null or v_foreign_amount <= 0 then
        v_foreign_amount := greatest(coalesce(v_debit, 0), coalesce(v_credit, 0));
      end if;
      if v_foreign_amount is null or v_foreign_amount <= 0 then
        raise exception 'foreignAmount required for currency %', v_currency_code;
      end if;
      v_base_amount := public._money_round(v_foreign_amount * v_fx_rate);
      if v_debit > 0 then
        v_debit := v_base_amount;
        v_credit := 0;
      else
        v_credit := v_base_amount;
        v_debit := 0;
      end if;
    else
      v_currency_code := null;
      v_fx_rate := null;
      v_foreign_amount := null;
    end if;

    v_memo := nullif(trim(coalesce(v_line->>'memo', '')), '');

    insert into public.journal_lines(
      journal_entry_id,
      account_id,
      debit,
      credit,
      line_memo,
      cost_center_id,
      party_id,
      currency_code,
      fx_rate,
      foreign_amount
    )
    values (
      v_entry_id,
      v_account_id,
      v_debit,
      v_credit,
      v_memo,
      v_cost_center_id,
      v_party_id,
      v_currency_code,
      v_fx_rate,
      v_foreign_amount
    );
  end loop;

  perform public.check_journal_entry_balance(v_entry_id);
  return v_entry_id;
end;
$$;

revoke all on function public.create_manual_journal_entry(timestamptz, text, jsonb, uuid) from public;
grant execute on function public.create_manual_journal_entry(timestamptz, text, jsonb, uuid) to authenticated;

notify pgrst, 'reload schema';
