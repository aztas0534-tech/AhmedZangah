set app.allow_ledger_ddl = '1';

create or replace function public.create_party_document(
  p_doc_type text,
  p_occurred_at timestamptz,
  p_party_id uuid,
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
  v_doc_id uuid;
  v_doc_number text;
  v_line jsonb;
  v_lines_clean jsonb := '[]'::jsonb;
  v_line_clean jsonb;
  v_currency_code text;
  v_foreign_amount numeric;
  v_base text;
begin
  if not public.has_admin_permission('accounting.manage') then
    raise exception 'not allowed';
  end if;

  if p_party_id is null then
    raise exception 'party_id is required';
  end if;

  if p_doc_type is null or lower(trim(p_doc_type)) not in (
    'ar_invoice','ap_bill','ar_receipt','ap_payment','advance','custodian',
    'ar_credit_note','ap_credit_note','ar_debit_note','ap_debit_note'
  ) then
    raise exception 'invalid doc_type';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'p_lines must be a json array';
  end if;

  v_base := public.get_base_currency();

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'invalid line';
    end if;

    v_line_clean := v_line - 'fxRate';
    v_currency_code := upper(nullif(trim(coalesce(v_line->>'currencyCode', '')), ''));
    v_foreign_amount := null;
    begin
      v_foreign_amount := nullif(trim(coalesce(v_line->>'foreignAmount', '')), '')::numeric;
    exception when others then
      v_foreign_amount := null;
    end;

    if v_currency_code is null then
      v_line_clean := v_line_clean - 'currencyCode' - 'foreignAmount';
    elsif upper(v_currency_code) = upper(v_base) then
      v_line_clean := v_line_clean - 'currencyCode' - 'foreignAmount';
    else
      if not exists (select 1 from public.currencies c where upper(c.code) = v_currency_code limit 1) then
        raise exception 'unsupported currency: %', v_currency_code;
      end if;
      if v_foreign_amount is null or v_foreign_amount <= 0 then
        raise exception 'foreignAmount required for currency %', v_currency_code;
      end if;
      v_line_clean := jsonb_set(v_line_clean, '{currencyCode}', to_jsonb(v_currency_code), true);
      v_line_clean := jsonb_set(v_line_clean, '{foreignAmount}', to_jsonb(v_foreign_amount), true);
    end if;

    v_lines_clean := v_lines_clean || jsonb_build_array(v_line_clean);
  end loop;

  v_doc_number := public.generate_party_document_number(p_doc_type);

  insert into public.party_documents(doc_type, doc_number, occurred_at, memo, party_id, status, created_by, lines)
  values (
    lower(trim(p_doc_type)),
    v_doc_number,
    coalesce(p_occurred_at, now()),
    nullif(trim(coalesce(p_memo,'')),''),
    p_party_id,
    'draft',
    auth.uid(),
    v_lines_clean
  )
  returning id into v_doc_id;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'party_documents.create',
    'documents',
    v_doc_id::text,
    auth.uid(),
    now(),
    jsonb_build_object('documentId', v_doc_id::text, 'docNumber', v_doc_number, 'docType', lower(trim(p_doc_type))),
    'LOW',
    'DOCUMENT_CREATE'
  );

  return v_doc_id;
end;
$$;

revoke all on function public.create_party_document(text, timestamptz, uuid, text, jsonb, uuid) from public;
grant execute on function public.create_party_document(text, timestamptz, uuid, text, jsonb, uuid) to authenticated;

notify pgrst, 'reload schema';
