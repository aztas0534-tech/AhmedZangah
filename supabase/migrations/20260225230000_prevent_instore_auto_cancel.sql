create or replace function public.trg_prevent_instore_auto_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src text;
  v_reason text;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  if coalesce(old.status, '') <> 'pending' then
    return new;
  end if;

  if coalesce(new.status, '') <> 'cancelled' then
    return new;
  end if;

  v_src := coalesce(nullif(btrim(coalesce(new.data->>'orderSource','')), ''), nullif(btrim(coalesce(old.data->>'orderSource','')), ''), '');
  if v_src <> 'in_store' then
    return new;
  end if;

  if nullif(btrim(coalesce(new.data->>'deliveredAt','')), '') is not null then
    return new;
  end if;

  v_reason := nullif(btrim(coalesce(new.data->>'cancelReason','')), '');
  if v_reason is null then
    v_reason := 'in_store_failed';
  end if;

  new.status := 'pending';
  new.data := coalesce(new.data, '{}'::jsonb);
  new.data := jsonb_set(new.data, '{inStoreFailureAt}', to_jsonb(now()), true);
  new.data := jsonb_set(new.data, '{inStoreFailureReason}', to_jsonb(v_reason), true);
  return new;
end;
$$;

drop trigger if exists trg_prevent_instore_auto_cancel on public.orders;
create trigger trg_prevent_instore_auto_cancel
before update on public.orders
for each row execute function public.trg_prevent_instore_auto_cancel();

revoke all on function public.trg_prevent_instore_auto_cancel() from public;

notify pgrst, 'reload schema';

