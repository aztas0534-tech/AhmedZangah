set app.allow_ledger_ddl = '1';

create or replace function public.trg_orders_autofill_paidat_on_delivery()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source text;
  v_method text;
  v_terms text;
  v_paid_at text;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  if lower(coalesce(old.status, '')) = 'delivered' then
    return new;
  end if;
  if lower(coalesce(new.status, '')) <> 'delivered' then
    return new;
  end if;

  v_source := lower(coalesce(new.data->>'orderSource', ''));
  v_method := lower(coalesce(new.data->>'paymentMethod', ''));
  v_terms := lower(coalesce(new.data->>'invoiceTerms', ''));
  v_paid_at := nullif(coalesce(new.data->>'paidAt', ''), '');

  if v_source = 'in_store' and v_method = 'cash' and v_terms <> 'credit' and v_paid_at is null then
    new.data := jsonb_set(coalesce(new.data, '{}'::jsonb), '{paidAt}', to_jsonb(coalesce(new.updated_at, now())::text), true);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_orders_autofill_paidat_on_delivery on public.orders;
create trigger trg_orders_autofill_paidat_on_delivery
before update on public.orders
for each row
execute function public.trg_orders_autofill_paidat_on_delivery();

notify pgrst, 'reload schema';
