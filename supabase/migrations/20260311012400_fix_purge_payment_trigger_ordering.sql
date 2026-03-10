-- ═══════════════════════════════════════════════════════════════
-- purge_order_payment v10: Fix trigger ordering
-- Move order update & AR reopen BEFORE re-enabling triggers
-- Error fixed: posted_order_immutable
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

create or replace function public.purge_order_payment(
  p_order_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_payment_ids uuid[];
  v_je_ids uuid[];
  v_jl_ids uuid[];
  v_doc_ids uuid[];
  v_deleted_payments int := 0;
  v_deleted_journals int := 0;
  v_deleted_party_ledger int := 0;
  v_deleted_open_items int := 0;
  v_reason text;
begin
  if not public.is_owner() then
    raise exception 'only the owner can purge payments';
  end if;
  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

  v_reason := nullif(trim(coalesce(p_reason, '')), '');

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order not found';
  end if;

  perform set_config('app.allow_ledger_ddl', '1', true);

  -- ══════════════════════════════════════════════════════════════
  -- Disable ALL user triggers on ALL affected tables
  -- ══════════════════════════════════════════════════════════════
  alter table public.journal_lines         disable trigger user;
  alter table public.journal_entries       disable trigger user;
  alter table public.payments              disable trigger user;
  alter table public.party_ledger_entries   disable trigger user;
  alter table public.party_open_items      disable trigger user;
  alter table public.orders                disable trigger user;

  begin alter table public.accounting_documents     disable trigger user; exception when others then null; end;
  begin alter table public.settlement_lines          disable trigger user; exception when others then null; end;
  begin alter table public.settlement_headers        disable trigger user; exception when others then null; end;
  begin alter table public.ar_open_items             disable trigger user; exception when others then null; end;
  begin alter table public.ar_allocations            disable trigger user; exception when others then null; end;
  begin alter table public.ar_payment_status         disable trigger user; exception when others then null; end;
  begin alter table public.bank_reconciliation_matches disable trigger user; exception when others then null; end;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 0: Collect all IDs upfront
  -- ══════════════════════════════════════════════════════════════
  select coalesce(array_agg(p.id), '{}')
  into v_payment_ids
  from public.payments p
  where p.reference_table = 'orders' and p.reference_id = p_order_id::text;

  select coalesce(array_agg(je.id), '{}')
  into v_je_ids
  from public.journal_entries je
  where je.source_table = 'payments' and je.source_id = any(
    select pid::text from unnest(v_payment_ids) pid
  );

  select coalesce(array_agg(jl.id), '{}')
  into v_jl_ids
  from public.journal_lines jl
  where jl.journal_entry_id = any(v_je_ids);

  select coalesce(array_agg(distinct je.document_id), '{}')
  into v_doc_ids
  from public.journal_entries je
  where je.id = any(v_je_ids) and je.document_id is not null;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 1: Delete settlement chain
  -- ══════════════════════════════════════════════════════════════
  if array_length(v_jl_ids, 1) > 0 then
    begin
      delete from public.settlement_lines
      where from_open_item_id in (
        select poi.id from public.party_open_items poi where poi.journal_line_id = any(v_jl_ids)
      )
      or to_open_item_id in (
        select poi.id from public.party_open_items poi where poi.journal_line_id = any(v_jl_ids)
      );
    exception when others then null;
    end;
    begin
      delete from public.settlement_headers sh
      where not exists (select 1 from public.settlement_lines sl where sl.settlement_id = sh.id);
    exception when others then null;
    end;
  end if;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 2: Delete all tables referencing payments
  -- ══════════════════════════════════════════════════════════════
  if array_length(v_payment_ids, 1) > 0 then
    begin delete from public.ar_allocations where payment_id = any(v_payment_ids); exception when others then null; end;
    begin delete from public.ar_payment_status where payment_id = any(v_payment_ids); exception when others then null; end;
    begin delete from public.bank_reconciliation_matches where payment_id = any(v_payment_ids); exception when others then null; end;
  end if;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 3: Delete tables referencing journal_lines
  -- ══════════════════════════════════════════════════════════════
  if array_length(v_jl_ids, 1) > 0 then
    begin
      delete from public.party_open_items where journal_line_id = any(v_jl_ids);
      get diagnostics v_deleted_open_items = row_count;
    exception when others then null;
    end;
    begin
      delete from public.party_ledger_entries where journal_line_id = any(v_jl_ids);
      get diagnostics v_deleted_party_ledger = row_count;
    exception when others then null;
    end;
    delete from public.journal_lines where id = any(v_jl_ids);
  end if;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 4: Delete tables referencing journal_entries, then entries
  -- ══════════════════════════════════════════════════════════════
  if array_length(v_je_ids, 1) > 0 then
    begin delete from public.ar_open_items where journal_entry_id = any(v_je_ids); exception when others then null; end;
    delete from public.journal_entries where id = any(v_je_ids);
    v_deleted_journals := array_length(v_je_ids, 1);
  end if;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 5: Delete payments
  -- ══════════════════════════════════════════════════════════════
  if array_length(v_payment_ids, 1) > 0 then
    delete from public.payments where id = any(v_payment_ids);
    get diagnostics v_deleted_payments = row_count;
  end if;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 6: Delete accounting_documents
  -- ══════════════════════════════════════════════════════════════
  if array_length(v_doc_ids, 1) > 0 then
    begin delete from public.accounting_documents where id = any(v_doc_ids); exception when others then null; end;
  end if;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 7: Update order & reopen AR (WHILE triggers still disabled!)
  -- ══════════════════════════════════════════════════════════════
  update public.orders
  set data = (
    coalesce(data, '{}'::jsonb) - 'paidAt'
    || jsonb_build_object(
      'paymentPurgedAt', now()::text,
      'paymentPurgedBy', auth.uid()::text,
      'paymentPurgeReason', coalesce(v_reason, 'دفعة خاطئة')
    )
  ),
  updated_at = now()
  where id = p_order_id;

  begin
    update public.ar_open_items
    set status = 'open', closed_at = null, open_balance = original_amount
    where invoice_id = p_order_id and status = 'closed';
  exception when others then null;
  end;

  -- ══════════════════════════════════════════════════════════════
  -- Phase 8: Re-enable ALL user triggers (AFTER all mutations done)
  -- ══════════════════════════════════════════════════════════════
  alter table public.journal_lines         enable trigger user;
  alter table public.journal_entries       enable trigger user;
  alter table public.payments              enable trigger user;
  alter table public.party_ledger_entries   enable trigger user;
  alter table public.party_open_items      enable trigger user;
  alter table public.orders                enable trigger user;

  begin alter table public.accounting_documents     enable trigger user; exception when others then null; end;
  begin alter table public.settlement_lines          enable trigger user; exception when others then null; end;
  begin alter table public.settlement_headers        enable trigger user; exception when others then null; end;
  begin alter table public.ar_open_items             enable trigger user; exception when others then null; end;
  begin alter table public.ar_allocations            enable trigger user; exception when others then null; end;
  begin alter table public.ar_payment_status         enable trigger user; exception when others then null; end;
  begin alter table public.bank_reconciliation_matches enable trigger user; exception when others then null; end;

  perform set_config('app.allow_ledger_ddl', '', true);

  -- Audit (safe — system_audit_logs has no blocking triggers)
  insert into public.system_audit_logs(
    action, module, details, performed_by, performed_at, metadata, risk_level, reason_code
  ) values (
    'payment.purge', 'payments',
    concat('Purged payments for order ', right(p_order_id::text, 8)),
    auth.uid(), now(),
    jsonb_build_object(
      'orderId', p_order_id::text,
      'reason', coalesce(v_reason, 'دفعة خاطئة'),
      'deletedPayments', v_deleted_payments,
      'deletedJournals', coalesce(v_deleted_journals, 0),
      'deletedPartyLedger', v_deleted_party_ledger,
      'deletedOpenItems', v_deleted_open_items
    ),
    'CRITICAL', 'PAYMENT_PURGE'
  );

  return jsonb_build_object(
    'success', true,
    'deletedPayments', v_deleted_payments,
    'deletedJournals', coalesce(v_deleted_journals, 0),
    'deletedPartyLedger', v_deleted_party_ledger,
    'deletedOpenItems', v_deleted_open_items
  );
end;
$$;

revoke all on function public.purge_order_payment(uuid, text) from public;
grant execute on function public.purge_order_payment(uuid, text) to authenticated;

notify pgrst, 'reload schema';
