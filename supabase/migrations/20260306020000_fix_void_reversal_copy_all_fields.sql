set app.allow_ledger_ddl = '1';

-- Fix void_journal_entry: copy party_id, currency_code, fx_rate, foreign_amount
-- into reversal lines so that:
-- 1. Reversal entries appear in party ledger statements
-- 2. FX data is preserved for audit trail
-- 3. Party balances are correctly adjusted on void

create or replace function public.void_journal_entry(
  p_entry_id uuid,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.journal_entries%rowtype;
  v_new_entry_id uuid;
  v_line record;
  v_reason text;
begin
  if not public.has_admin_permission('accounting.void') then
    raise exception 'not allowed';
  end if;
  if p_entry_id is null then
    raise exception 'p_entry_id is required';
  end if;
  select * into v_entry from public.journal_entries where id = p_entry_id;
  if not found then
    raise exception 'journal entry not found';
  end if;
  if v_entry.source_table = 'manual' and v_entry.status = 'draft' then
    raise exception 'not allowed';
  end if;
  v_reason := nullif(trim(coalesce(p_reason,'')), '');
  if v_reason is null then
    raise exception 'reason required';
  end if;
  perform public.set_audit_reason(v_reason);

  perform set_config('app.accounting_bypass', '1', true);
  update public.journal_entries
  set status = 'voided',
      voided_by = auth.uid(),
      voided_at = now(),
      void_reason = v_reason
  where id = p_entry_id;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
  values (now(), concat('Void ', p_entry_id::text, ' ', coalesce(v_entry.memo,'')), 'journal_entries', p_entry_id::text, 'void', auth.uid())
  returning id into v_new_entry_id;

  for v_line in
    select account_id, debit, credit, line_memo, cost_center_id,
           party_id, currency_code, fx_rate, foreign_amount
    from public.journal_lines where journal_entry_id = p_entry_id
  loop
    insert into public.journal_lines(
      journal_entry_id, account_id, debit, credit, line_memo, cost_center_id,
      party_id, currency_code, fx_rate, foreign_amount
    )
    values (
      v_new_entry_id, v_line.account_id,
      v_line.credit, v_line.debit,
      coalesce(v_line.line_memo,'') || ' (reversal)',
      v_line.cost_center_id,
      v_line.party_id,
      v_line.currency_code,
      v_line.fx_rate,
      v_line.foreign_amount
    );
  end loop;

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values ('journal_entries.void', 'accounting', p_entry_id::text, auth.uid(), now(),
          jsonb_build_object('voidOf', p_entry_id::text, 'newEntryId', v_new_entry_id::text),
          'HIGH', v_reason);
  return v_new_entry_id;
end;
$$;

revoke all on function public.void_journal_entry(uuid, text) from public;
grant execute on function public.void_journal_entry(uuid, text) to authenticated;

notify pgrst, 'reload schema';
