-- ═══════════════════════════════════════════════════════════════
-- purge_order_payment v2: Fix — disable ALL append-only triggers
-- before deleting journal lines, journal entries, payments,
-- and party ledger entries.
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
  v_payment record;
  v_je_id uuid;
  v_deleted_payments int := 0;
  v_deleted_journals int := 0;
  v_deleted_party_ledger int := 0;
  v_reason text;
begin
  -- Owner only
  if not public.is_owner() then
    raise exception 'only the owner can purge payments';
  end if;

  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

  v_reason := nullif(trim(coalesce(p_reason, '')), '');

  -- Verify order exists
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order not found';
  end if;

  -- ── Disable ALL append-only / immutability triggers ──
  alter table public.journal_lines disable trigger trg_journal_lines_block_system_mutation;
  alter table public.journal_entries disable trigger trg_journal_entries_block_system_mutation;
  alter table public.payments disable trigger trg_payments_forbid_delete_posted;

  -- Safely disable party_ledger trigger (may not exist in some deployments)
  begin
    alter table public.party_ledger_entries disable trigger trg_party_ledger_entries_append_only;
  exception when others then
    null;
  end;

  -- ── 1. Delete journal entries + lines linked to payments for this order ──
  for v_payment in
    select p.id
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
  loop
    -- Find ALL journal entries for this payment (including 'void' reversals)
    for v_je_id in
      select je.id
      from public.journal_entries je
      where je.source_table = 'payments'
        and je.source_id = v_payment.id::text
    loop
      -- Delete party ledger entries linked to these journal lines
      begin
        delete from public.party_ledger_entries
        where journal_line_id in (
          select jl.id from public.journal_lines jl
          where jl.journal_entry_id = v_je_id
        );
        get diagnostics v_deleted_party_ledger = row_count;
      exception when others then
        null; -- party_ledger_entries may not exist
      end;

      -- Delete journal lines
      delete from public.journal_lines where journal_entry_id = v_je_id;
      -- Delete journal entry
      delete from public.journal_entries where id = v_je_id;
      v_deleted_journals := v_deleted_journals + 1;
    end loop;
  end loop;

  -- ── 2. Delete all payment records for this order ──
  delete from public.payments
  where reference_table = 'orders'
    and reference_id = p_order_id::text;
  get diagnostics v_deleted_payments = row_count;

  -- ── Re-enable ALL triggers ──
  alter table public.journal_lines enable trigger trg_journal_lines_block_system_mutation;
  alter table public.journal_entries enable trigger trg_journal_entries_block_system_mutation;
  alter table public.payments enable trigger trg_payments_forbid_delete_posted;

  begin
    alter table public.party_ledger_entries enable trigger trg_party_ledger_entries_append_only;
  exception when others then
    null;
  end;

  -- ── 3. Reset paidAt on the order ──
  update public.orders
  set data = (
    coalesce(data, '{}'::jsonb)
    - 'paidAt'
    || jsonb_build_object(
      'paymentPurgedAt', now()::text,
      'paymentPurgedBy', auth.uid()::text,
      'paymentPurgeReason', coalesce(v_reason, 'دفعة خاطئة')
    )
  ),
  updated_at = now()
  where id = p_order_id;

  -- ── 4. Reopen AR open items if they were closed by payment ──
  begin
    update public.ar_open_items
    set status = 'open',
        closed_at = null,
        open_balance = original_amount
    where invoice_id = p_order_id
      and status = 'closed';
  exception when others then
    null;
  end;

  -- ── 5. Audit log ──
  insert into public.system_audit_logs(
    action, module, details, performed_by, performed_at, metadata, risk_level, reason_code
  ) values (
    'payment.purge',
    'payments',
    concat('Purged all payments for order ', right(p_order_id::text, 8)),
    auth.uid(),
    now(),
    jsonb_build_object(
      'orderId', p_order_id::text,
      'reason', coalesce(v_reason, 'دفعة خاطئة'),
      'deletedPayments', v_deleted_payments,
      'deletedJournals', v_deleted_journals,
      'deletedPartyLedger', v_deleted_party_ledger
    ),
    'CRITICAL',
    'PAYMENT_PURGE'
  );

  return jsonb_build_object(
    'success', true,
    'deletedPayments', v_deleted_payments,
    'deletedJournals', v_deleted_journals,
    'deletedPartyLedger', v_deleted_party_ledger
  );
end;
$$;

revoke all on function public.purge_order_payment(uuid, text) from public;
grant execute on function public.purge_order_payment(uuid, text) to authenticated;

notify pgrst, 'reload schema';
