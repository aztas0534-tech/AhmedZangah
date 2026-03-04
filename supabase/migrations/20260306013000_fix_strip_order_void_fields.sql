-- Fix _strip_order_return_fields to also strip void-related fields.
-- Without this, void_delivered_order fails because the trigger
-- trg_orders_forbid_posted_updates sees data changes (voidedAt, voidReason, voidedBy)
-- and raises posted_order_immutable.

create or replace function public._strip_order_return_fields(p jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(p, '{}'::jsonb)
    - 'returnStatus'
    - 'returnedAt'
    - 'returnUpdatedAt'
    - 'voidedAt'
    - 'voidReason'
    - 'voidedBy'
$$;

notify pgrst, 'reload schema';
