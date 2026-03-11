set app.allow_ledger_ddl = '1';

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

  v_base := public.get_base_currency();
  v_entry_date := coalesce(p_entry_date, now());
  v_memo := nullif(trim(coalesce(p_memo, '')), '');
  v_journal_id := coalesce(p_journal_id, public.get_default_journal_id(), '00000000-0000-4000-8000-000000000001'::uuid);

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, journal_id)
  values (
    v_entry_date,
    v_memo,
    'manual',
    null,
    v_type,
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
      if v_currency_code = v_base then
        v_fx_rate := 1;
      else
        v_fx_rate := public.get_fx_rate(v_currency_code, v_entry_date::date, 'operational');
        if v_fx_rate is null or v_fx_rate <= 0 then
          raise exception 'missing fx rate for % on %', v_currency_code, v_entry_date::date;
        end if;
      end if;
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

revoke all on function public.create_manual_voucher(text, timestamptz, text, jsonb, uuid) from public;
grant execute on function public.create_manual_voucher(text, timestamptz, text, jsonb, uuid) to authenticated;

create or replace function public.approve_party_document(p_document_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc public.party_documents%rowtype;
  v_entry_id uuid;
  v_line jsonb;
  v_account_code text;
  v_account_id uuid;
  v_debit numeric;
  v_credit numeric;
  v_line_memo text;
  v_cost_center_id uuid;
  v_party_line_id uuid;
  v_currency_code text;
  v_fx_rate numeric;
  v_foreign_amount numeric;
  v_journal_id uuid;
  v_base text;
begin
  if not public.has_admin_permission('accounting.approve') then
    raise exception 'not allowed';
  end if;
  if p_document_id is null then
    raise exception 'document_id is required';
  end if;

  select * into v_doc
  from public.party_documents
  where id = p_document_id
  for update;

  if not found then
    raise exception 'document not found';
  end if;

  if v_doc.status <> 'draft' then
    return coalesce(v_doc.journal_entry_id, p_document_id);
  end if;

  if v_doc.journal_entry_id is not null then
    return v_doc.journal_entry_id;
  end if;

  if v_doc.lines is null or jsonb_typeof(v_doc.lines) <> 'array' then
    raise exception 'invalid stored lines';
  end if;

  v_base := public.get_base_currency();
  v_journal_id := coalesce(public.get_default_journal_id(), '00000000-0000-4000-8000-000000000001'::uuid);

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, journal_id)
  values (
    v_doc.occurred_at,
    concat(v_doc.doc_number, case when nullif(trim(coalesce(v_doc.memo,'')),'') is null then '' else concat(' - ', nullif(trim(coalesce(v_doc.memo,'')),'') ) end),
    'party_documents',
    v_doc.id::text,
    v_doc.doc_type,
    auth.uid(),
    v_journal_id
  )
  returning id into v_entry_id;

  for v_line in select value from jsonb_array_elements(v_doc.lines)
  loop
    v_account_code := nullif(trim(coalesce(v_line->>'accountCode', '')), '');
    v_debit := coalesce(nullif(v_line->>'debit', '')::numeric, 0);
    v_credit := coalesce(nullif(v_line->>'credit', '')::numeric, 0);
    v_line_memo := nullif(trim(coalesce(v_line->>'memo', '')), '');
    v_cost_center_id := nullif(trim(coalesce(v_line->>'costCenterId', '')), '')::uuid;
    v_party_line_id := nullif(trim(coalesce(v_line->>'partyId', '')), '')::uuid;
    v_currency_code := upper(nullif(trim(coalesce(v_line->>'currencyCode', '')), ''));
    v_fx_rate := null;
    v_foreign_amount := null;
    begin
      v_foreign_amount := nullif(trim(coalesce(v_line->>'foreignAmount', '')), '')::numeric;
    exception when others then
      v_foreign_amount := null;
    end;

    if v_account_code is null then
      raise exception 'accountCode is required';
    end if;

    if v_debit < 0 or v_credit < 0 then
      raise exception 'invalid debit/credit';
    end if;

    if (v_debit > 0 and v_credit > 0) or (v_debit = 0 and v_credit = 0) then
      raise exception 'invalid line amounts';
    end if;

    if v_party_line_id is not null and v_party_line_id <> v_doc.party_id then
      raise exception 'partyId mismatch';
    end if;

    v_account_id := public.get_account_id_by_code(v_account_code);
    if v_account_id is null then
      raise exception 'account not found %', v_account_code;
    end if;

    if v_currency_code is not null then
      if not exists (select 1 from public.currencies c where upper(c.code) = v_currency_code limit 1) then
        raise exception 'unsupported currency: %', v_currency_code;
      end if;
      if v_currency_code = v_base then
        v_fx_rate := 1;
      else
        v_fx_rate := public.get_fx_rate(v_currency_code, v_doc.occurred_at::date, 'operational');
        if v_fx_rate is null or v_fx_rate <= 0 then
          raise exception 'missing fx rate for % on %', v_currency_code, v_doc.occurred_at::date;
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
    )
    values (
      v_entry_id,
      v_account_id,
      v_debit,
      v_credit,
      v_line_memo,
      v_cost_center_id,
      v_party_line_id,
      v_currency_code,
      v_fx_rate,
      v_foreign_amount
    );
  end loop;

  perform public.check_journal_entry_balance(v_entry_id);

  update public.party_documents
  set status = 'posted',
      journal_entry_id = v_entry_id,
      approved_by = auth.uid(),
      approved_at = now()
  where id = p_document_id;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'party_documents.approve',
    'documents',
    p_document_id::text,
    auth.uid(),
    now(),
    jsonb_build_object('documentId', p_document_id::text, 'docNumber', v_doc.doc_number, 'docType', v_doc.doc_type, 'journalEntryId', v_entry_id::text),
    'MEDIUM',
    'DOCUMENT_APPROVE'
  );

  return v_entry_id;
end;
$$;

revoke all on function public.approve_party_document(uuid) from public;
grant execute on function public.approve_party_document(uuid) to authenticated;

do $$
begin
  if to_regclass('public.currencies') is not null then
    begin
      grant select on table public.currencies to authenticated;
    exception when others then
      null;
    end;
    drop policy if exists currencies_read_authenticated on public.currencies;
    create policy currencies_read_authenticated on public.currencies
      for select using (auth.role() = 'authenticated');
  end if;

  if to_regclass('public.fx_rates') is not null then
    begin
      grant select on table public.fx_rates to authenticated;
    exception when others then
      null;
    end;
    drop policy if exists fx_rates_read_authenticated on public.fx_rates;
    create policy fx_rates_read_authenticated on public.fx_rates
      for select using (auth.role() = 'authenticated');
  end if;
end $$;

notify pgrst, 'reload schema';
