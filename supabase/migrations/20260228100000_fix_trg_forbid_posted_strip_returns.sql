-- Fix: trg_orders_forbid_posted_updates was overwritten in 20260222170000
-- without _strip_order_return_fields, blocking sales returns from updating
-- returnStatus / returnedAt / returnUpdatedAt on delivered orders.

create or replace function public.trg_orders_forbid_posted_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status = 'delivered' then
    if (public._strip_order_return_fields(new.data) is distinct from public._strip_order_return_fields(old.data))
      or (new.currency is distinct from old.currency)
      or (new.fx_rate is distinct from old.fx_rate)
      or (new.base_total is distinct from old.base_total)
      or (new.warehouse_id is distinct from old.warehouse_id)
      or (new.party_id is distinct from old.party_id)
    then
      raise exception 'posted_order_immutable';
    end if;
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';
