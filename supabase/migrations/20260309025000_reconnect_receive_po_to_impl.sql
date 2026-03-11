-- =======================================================================
-- FIX: Reconnect receive_purchase_order_partial → _impl
--
-- Problem:  Migration 20260228072000 + 20260228233500 replaced the
--           wrapper with a simplified standalone that lost:
--           - FX conversion (foreign costs treated as base)
--           - UOM conversion (quantities not converted to base)
--           - Idempotency key support
--           - Batch foreign_currency / fx_rate_at_receipt
--           - posting_status tracking
--           - QC hold for food items
--
-- Fix:      Restore the wrapper to delegate to _receive_purchase_order_partial_impl
--           which contains the full, correct logic (last updated 20260227013200).
--
-- Safety:   _impl has the same signature (uuid, jsonb, timestamptz) → uuid.
--           It already handles qty_base comparison (lines 235-246).
--           Frontend sends idempotencyKey, uomCode, harvestDate, expiryDate
--           which _impl processes but the simplified version ignores.
-- =======================================================================

set app.allow_ledger_ddl = '1';

-- Verify _impl exists before replacing
do $$
begin
  if to_regprocedure('public._receive_purchase_order_partial_impl(uuid,jsonb,timestamptz)') is null then
    raise exception '_receive_purchase_order_partial_impl not found — cannot reconnect';
  end if;
end $$;

create or replace function public.receive_purchase_order_partial(
  p_order_id uuid,
  p_items jsonb,
  p_occurred_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  return public._receive_purchase_order_partial_impl(p_order_id, p_items, p_occurred_at);
end;
$$;

revoke all on function public.receive_purchase_order_partial(uuid, jsonb, timestamptz) from public;
grant execute on function public.receive_purchase_order_partial(uuid, jsonb, timestamptz) to authenticated;

notify pgrst, 'reload schema';
