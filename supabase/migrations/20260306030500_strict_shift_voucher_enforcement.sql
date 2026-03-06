set app.allow_ledger_ddl = '1';

-- Drop and recreate the RPC with the strict shift enforcement logic for cash
drop function if exists public.create_manual_voucher(text, timestamptz, text, jsonb, uuid);

create or replace function public.create_manual_voucher(
  p_voucher_type text,
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
  v_type text;
  v_base text;
  v_entry_date timestamptz;
  v_shift_id uuid;
  v_has_cash_account boolean := false;
  v_cash_account_code_prefix varchar := '1010'; -- Prefix for Cash accounts, assuming standard chart of accounts
begin
  if not public.has_admin_permission('accounting.manage') then
    raise exception 'not allowed';
  end if;

  v_type := lower(nullif(btrim(coalesce(p_voucher_type,'')), ''));
  if v_type not in ('receipt','payment','journal') then
    raise exception 'invalid voucher_type';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'p_lines must be a json array';
  end if;

  -- 🌟 Preliminary Check: Does this voucher involve a Cash account? 🌟
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_account_code := nullif(trim(coalesce(v_line->>'accountCode', '')), '');
    if v_account_code is not null and v_account_code like v_cash_account_code_prefix || '%' then
       v_has_cash_account := true;
       exit; 
    end if;
  end loop;

  -- 🌟 Resolve active cash shift for the current user 🌟
  v_shift_id := public._resolve_open_shift_for_cash(auth.uid());

  -- 🌟 Strict Control: enforce active shift if a cash account is used 🌟
  if v_has_cash_account and v_shift_id is null then
    raise exception 'لا يمكنك إنشاء سند نقدي بدون فتح وردية صندوق أولاً.';
  end if;


  v_base := public.get_base_currency();
  v_entry_date := coalesce(p_entry_date, now());
  v_memo := nullif(trim(coalesce(p_memo, '')), '');
  v_journal_id := coalesce(p_journal_id, public.get_default_journal_id(), '00000000-0000-4000-8000-000000000001'::uuid);


  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, journal_id, shift_id)
  values (
    v_entry_date,
    v_memo,
    'manual',
    null,
    v_type,
    auth.uid(),
    v_journal_id,
    v_shift_id
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
      if v_currency_code = v_base then
        v_currency_code := null;
        v_foreign_amount := null;
        v_fx_rate := null;
      else
        if (v_debit > 0 and (v_foreign_amount is null or v_foreign_amount <= 0)) or
           (v_credit > 0 and (v_foreign_amount is null or v_foreign_amount <= 0)) then
             v_currency_code := null;
             v_foreign_amount := null;
             v_fx_rate := null;
        else
          begin
            v_fx_rate := nullif(v_line->>'fxRate', '')::numeric;
            if v_fx_rate is not null and v_fx_rate <= 0 then
              v_fx_rate := null;
            end if;
          exception when others then
            v_fx_rate := null;
          end;

          if v_fx_rate is null then
            v_fx_rate := public.get_fx_rate(v_currency_code, v_base);
            if v_fx_rate is null or v_fx_rate <= 0 then
              raise exception 'no valid fx rate for %', v_currency_code;
            end if;
          end if;

          if v_debit > 0 then
            v_debit := public._money_round(v_foreign_amount * v_fx_rate);
          else
            v_credit := public._money_round(v_foreign_amount * v_fx_rate);
          end if;
        end if;
      end if;
    end if;

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
    ) values (
      v_entry_id,
      v_account_id,
      v_debit,
      v_credit,
      nullif(trim(coalesce(v_line->>'memo', '')), ''),
      v_cost_center_id,
      v_party_id,
      v_currency_code,
      v_fx_rate,
      v_foreign_amount
    );
  end loop;

  perform public.verify_journal_entry_balance(v_entry_id);

  return v_entry_id;
end;
$$;

revoke all on function public.create_manual_voucher(text, timestamptz, text, jsonb, uuid) from public;
grant execute on function public.create_manual_voucher(text, timestamptz, text, jsonb, uuid) to authenticated;

notify pgrst, 'reload schema';
