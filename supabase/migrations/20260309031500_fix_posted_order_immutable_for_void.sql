set app.allow_ledger_ddl = '1';

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

drop trigger if exists trg_orders_forbid_posted_updates on public.orders;
create trigger trg_orders_forbid_posted_updates
before update on public.orders
for each row
execute function public.trg_orders_forbid_posted_updates();

notify pgrst, 'reload schema';
