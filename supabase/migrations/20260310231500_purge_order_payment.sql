-- ═══════════════════════════════════════════════════════════════
-- purge_order_payment: Hard-delete all payment records for an order
-- Removes: payments, journal_entries+journal_lines, and resets paidAt
-- Owner-only operation. Creates audit trail but removes financial traces.
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

  -- ── 1. Delete journal entries + lines linked to payments for this order ──
  for v_payment in
    select p.id
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
  loop
    -- Find journal entries for this payment
    for v_je_id in
      select je.id
      from public.journal_entries je
      where je.source_table = 'payments'
        and je.source_id = v_payment.id::text
    loop
      -- Delete journal lines first
      delete from public.journal_lines where journal_entry_id = v_je_id;
      -- Delete journal entry
      delete from public.journal_entries where id = v_je_id;
      v_deleted_journals := v_deleted_journals + 1;
    end loop;

    -- Also check for reversal journal entries (source_event = 'void')
    for v_je_id in
      select je.id
      from public.journal_entries je
      where je.source_table = 'payments'
        and je.source_id = v_payment.id::text
        and je.source_event = 'void'
    loop
      delete from public.journal_lines where journal_entry_id = v_je_id;
      delete from public.journal_entries where id = v_je_id;
      v_deleted_journals := v_deleted_journals + 1;
    end loop;
  end loop;

  -- ── 2. Delete all payment records for this order ──
  -- Temporarily allow deletion by disabling the forbid-delete trigger
  alter table public.payments disable trigger trg_payments_forbid_delete_posted;

  delete from public.payments
  where reference_table = 'orders'
    and reference_id = p_order_id::text;
  get diagnostics v_deleted_payments = row_count;

  alter table public.payments enable trigger trg_payments_forbid_delete_posted;

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
    null; -- AR table may not exist or have different schema
  end;

  -- ── 5. Audit log (we keep this to maintain accountability) ──
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
      'deletedJournals', v_deleted_journals
    ),
    'CRITICAL',
    'PAYMENT_PURGE'
  );

  return jsonb_build_object(
    'success', true,
    'deletedPayments', v_deleted_payments,
    'deletedJournals', v_deleted_journals
  );
end;
$$;

revoke all on function public.purge_order_payment(uuid, text) from public;
grant execute on function public.purge_order_payment(uuid, text) to authenticated;

notify pgrst, 'reload schema';
