set app.allow_ledger_ddl = '1';

-- Fix reverse_payment_journal to copy party_id, currency_code, fx_rate, foreign_amount, cost_center_id
create or replace function public.reverse_payment_journal(
  p_payment_id uuid,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text;
  v_existing_id uuid;
  v_new_entry_id uuid;
begin
  if not public.is_owner_or_manager() then
    raise exception 'not allowed';
  end if;
  if p_payment_id is null then
    raise exception 'p_payment_id is required';
  end if;
  v_reason := nullif(trim(coalesce(p_reason,'')), '');
  if v_reason is null then
    raise exception 'reason required';
  end if;
  perform public.set_audit_reason(v_reason);
  select id into v_existing_id
  from public.journal_entries
  where source_table = 'payments' and source_id = p_payment_id::text
  order by created_at desc
  limit 1;
  if v_existing_id is null then
    raise exception 'payment journal not found';
  end if;
  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
  values (now(), concat('Void payment ', p_payment_id::text), 'payments', p_payment_id::text, 'void', auth.uid())
  returning id into v_new_entry_id;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo,
    cost_center_id, party_id, currency_code, fx_rate, foreign_amount)
  select v_new_entry_id, account_id, credit, debit, coalesce(line_memo,'') || ' (reversal)',
    cost_center_id, party_id, currency_code, fx_rate, foreign_amount
  from public.journal_lines
  where journal_entry_id = v_existing_id;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('payments.void', 'payments', p_payment_id::text, auth.uid(), now(),
          jsonb_build_object('voidOfJournal', v_existing_id::text, 'newEntryId', v_new_entry_id::text),
          'HIGH', v_reason);
  return v_new_entry_id;
end;
$$;

notify pgrst, 'reload schema';
