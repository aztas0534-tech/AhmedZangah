set app.allow_ledger_ddl = '1';

create or replace function public.approve_order_payment_purge(
  p_request_id uuid,
  p_approval_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req record;
  v_allowed boolean := false;
  v_note text := trim(coalesce(p_approval_note, ''));
  v_payment_ids uuid[];
  v_pid uuid;
  v_orig_je record;
  v_new_je_id uuid;
  v_reversed_journals int := 0;
  v_locked_violation boolean := false;
begin
  if p_request_id is null then
    raise exception 'request id is required';
  end if;
  if char_length(v_note) < 10 then
    raise exception 'approval note must be at least 10 characters';
  end if;

  select (
    public.has_admin_permission('accounting.manage')
    or exists (
      select 1
      from public.admin_users au
      where au.auth_user_id = auth.uid()
        and au.is_active = true
        and au.role in ('owner','manager')
    )
  ) into v_allowed;
  if not v_allowed then
    raise exception 'not allowed';
  end if;

  select *
  into v_req
  from public.order_payment_purge_requests r
  where r.id = p_request_id
  for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_req.status <> 'requested' then
    raise exception 'request is not open';
  end if;
  if v_req.requested_by = auth.uid() then
    raise exception 'dual control violation: approver must be different from requester';
  end if;

  select coalesce(array_agg(p.id), '{}') into v_payment_ids
  from public.payments p
  where p.reference_table = 'orders'
    and p.reference_id = v_req.order_id::text
    and p.direction = 'in';

  if array_length(v_payment_ids, 1) is null then
    raise exception 'no payments to reverse';
  end if;

  select exists (
    select 1
    from public.payments p
    where p.id = any(v_payment_ids)
      and public.is_in_closed_period(p.occurred_at)
  ) into v_locked_violation;

  if not v_locked_violation then
    select exists (
      select 1
      from public.journal_entries je
      where je.source_table = 'payments'
        and je.source_id = any(select x::text from unnest(v_payment_ids) x)
        and public.is_in_closed_period(je.entry_date)
    ) into v_locked_violation;
  end if;

  if v_locked_violation then
    update public.order_payment_purge_requests
    set locked_period_violation = true
    where id = v_req.id;
    raise exception 'cannot execute purge reversal for closed accounting period';
  end if;

  for v_pid in select unnest(v_payment_ids)
  loop
    if not exists (
      select 1
      from public.journal_entries je
      where je.source_table = 'payments'
        and je.source_id = v_pid::text
        and coalesce(je.source_event, '') not in ('reversal', 'void', 'reversed')
        and coalesce(je.source_event, '') not like 'reversal:purge:%'
    ) then
      begin
        perform public.post_payment(v_pid);
      exception when others then
        null;
      end;
    end if;
  end loop;

  for v_orig_je in
    select je.*
    from public.journal_entries je
    where je.source_table = 'payments'
      and je.source_id = any(select x::text from unnest(v_payment_ids) x)
      and coalesce(je.source_event, '') not in ('reversal', 'void', 'reversed')
      and coalesce(je.source_event, '') not like 'reversal:purge:%'
      and not exists (
        select 1
        from public.journal_entries je2
        where je2.source_table = 'payments'
          and je2.source_id = je.source_id
          and je2.source_event = concat('reversal:purge:', je.id::text)
      )
  loop
    begin
      insert into public.journal_entries(
        entry_date, memo, source_table, source_id, source_event, created_by, status, currency_code, fx_rate, foreign_amount
      ) values (
        now(),
        concat('Reversal of payment JE ', right(v_orig_je.id::text, 8), ' by approved purge request'),
        'payments',
        v_orig_je.source_id,
        concat('reversal:purge:', v_orig_je.id::text),
        auth.uid(),
        coalesce(v_orig_je.status, 'posted'),
        v_orig_je.currency_code,
        v_orig_je.fx_rate,
        v_orig_je.foreign_amount
      )
      returning id into v_new_je_id;
    exception when undefined_column then
      insert into public.journal_entries(
        entry_date, memo, source_table, source_id, source_event, created_by
      ) values (
        now(),
        concat('Reversal of payment JE ', right(v_orig_je.id::text, 8), ' by approved purge request'),
        'payments',
        v_orig_je.source_id,
        concat('reversal:purge:', v_orig_je.id::text),
        auth.uid()
      )
      returning id into v_new_je_id;
    end;

    begin
      insert into public.journal_lines(
        journal_entry_id, account_id, debit, credit, line_memo, party_id, currency_code, fx_rate, foreign_amount
      )
      select
        v_new_je_id,
        jl.account_id,
        coalesce(jl.credit, 0),
        coalesce(jl.debit, 0),
        concat('Reversal: ', coalesce(jl.line_memo, '')),
        jl.party_id,
        jl.currency_code,
        jl.fx_rate,
        jl.foreign_amount
      from public.journal_lines jl
      where jl.journal_entry_id = v_orig_je.id;
    exception when undefined_column then
      insert into public.journal_lines(
        journal_entry_id, account_id, debit, credit, line_memo
      )
      select
        v_new_je_id,
        jl.account_id,
        coalesce(jl.credit, 0),
        coalesce(jl.debit, 0),
        concat('Reversal: ', coalesce(jl.line_memo, ''))
      from public.journal_lines jl
      where jl.journal_entry_id = v_orig_je.id;
    end;

    begin
      perform public.check_journal_entry_balance(v_new_je_id);
    exception when others then
      null;
    end;

    v_reversed_journals := v_reversed_journals + 1;
  end loop;

  if v_reversed_journals = 0 then
    update public.order_payment_purge_requests
    set status = 'executed',
        approval_note = v_note,
        approved_by = auth.uid(),
        approved_at = now(),
        executed_by = auth.uid(),
        executed_at = now(),
        execution_result = jsonb_build_object(
          'reversedJournals', 0,
          'mode', 'noop_already_reversed'
        )
    where id = v_req.id;

    insert into public.system_audit_logs(
      action, module, details, performed_by, performed_at, metadata, risk_level, reason_code
    ) values (
      'payment.purge.execute.noop',
      'payments',
      concat('Approved payment purge with no-op for order ', right(v_req.order_id::text, 8)),
      auth.uid(),
      now(),
      jsonb_build_object(
        'orderId', v_req.order_id::text,
        'requestId', v_req.id::text,
        'reason', v_req.reason,
        'reasonCategory', v_req.reason_category,
        'approvalNote', v_note
      ),
      'HIGH',
      'PAYMENT_PURGE_EXECUTE_NOOP'
    );

    return jsonb_build_object(
      'success', true,
      'requestId', v_req.id::text,
      'status', 'executed',
      'reversedJournals', 0,
      'mode', 'noop_already_reversed'
    );
  end if;

  update public.payments p
  set data = coalesce(p.data, '{}'::jsonb) || jsonb_build_object(
    'purgeControlled', true,
    'purgeRequestId', v_req.id::text,
    'purgeExecutedAt', now()::text,
    'purgeExecutedBy', auth.uid()::text,
    'purgeReason', v_req.reason,
    'purgeReasonCategory', v_req.reason_category
  )
  where p.id = any(v_payment_ids);

  update public.orders o
  set data = (
    (coalesce(o.data, '{}'::jsonb) - 'paidAt')
    || jsonb_build_object(
      'paymentPurgeRequestId', v_req.id::text,
      'paymentPurgeExecutedAt', now()::text,
      'paymentPurgeExecutedBy', auth.uid()::text,
      'paymentPurgeReason', v_req.reason,
      'paymentPurgeReasonCategory', v_req.reason_category,
      'paymentPurgeMode', 'reversal_entry'
    )
  ),
  updated_at = now()
  where o.id = v_req.order_id;

  update public.order_payment_purge_requests
  set status = 'executed',
      approval_note = v_note,
      approved_by = auth.uid(),
      approved_at = now(),
      executed_by = auth.uid(),
      executed_at = now(),
      execution_result = jsonb_build_object(
        'reversedJournals', v_reversed_journals,
        'mode', 'reversal_entry'
      )
  where id = v_req.id;

  insert into public.system_audit_logs(
    action, module, details, performed_by, performed_at, metadata, risk_level, reason_code
  ) values (
    'payment.purge.execute',
    'payments',
    concat('Executed payment purge reversal for order ', right(v_req.order_id::text, 8)),
    auth.uid(),
    now(),
    jsonb_build_object(
      'orderId', v_req.order_id::text,
      'requestId', v_req.id::text,
      'reason', v_req.reason,
      'reasonCategory', v_req.reason_category,
      'approvalNote', v_note,
      'reversedJournals', v_reversed_journals
    ),
    'CRITICAL',
    'PAYMENT_PURGE_EXECUTE'
  );

  return jsonb_build_object(
    'success', true,
    'requestId', v_req.id::text,
    'status', 'executed',
    'reversedJournals', v_reversed_journals
  );
end;
$$;

create or replace function public.bulk_request_order_payment_purge(
  p_order_ids uuid[],
  p_reason text,
  p_reason_category text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_requested int := 0;
  v_failed int := 0;
  v_errors jsonb := '[]'::jsonb;
begin
  if p_order_ids is null or array_length(p_order_ids, 1) is null then
    raise exception 'order ids are required';
  end if;
  foreach v_id in array p_order_ids
  loop
    begin
      perform public.request_order_payment_purge(v_id, p_reason, p_reason_category);
      v_requested := v_requested + 1;
    exception when others then
      v_failed := v_failed + 1;
      v_errors := v_errors || jsonb_build_object('orderId', v_id::text, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object(
    'success', true,
    'requested', v_requested,
    'failed', v_failed,
    'errors', v_errors
  );
end;
$$;

create or replace function public.bulk_approve_order_payment_purge(
  p_request_ids uuid[],
  p_approval_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_done int := 0;
  v_failed int := 0;
  v_reversed_total int := 0;
  v_res jsonb;
  v_errors jsonb := '[]'::jsonb;
begin
  if p_request_ids is null or array_length(p_request_ids, 1) is null then
    raise exception 'request ids are required';
  end if;
  foreach v_id in array p_request_ids
  loop
    begin
      select public.approve_order_payment_purge(v_id, p_approval_note) into v_res;
      v_done := v_done + 1;
      v_reversed_total := v_reversed_total + coalesce((v_res->>'reversedJournals')::int, 0);
    exception when others then
      v_failed := v_failed + 1;
      v_errors := v_errors || jsonb_build_object('requestId', v_id::text, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object(
    'success', true,
    'approved', v_done,
    'failed', v_failed,
    'reversedJournalsTotal', v_reversed_total,
    'errors', v_errors
  );
end;
$$;

revoke all on function public.bulk_request_order_payment_purge(uuid[], text, text) from public;
grant execute on function public.bulk_request_order_payment_purge(uuid[], text, text) to authenticated;
revoke all on function public.bulk_approve_order_payment_purge(uuid[], text) from public;
grant execute on function public.bulk_approve_order_payment_purge(uuid[], text) to authenticated;

notify pgrst, 'reload schema';
