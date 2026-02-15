set app.allow_ledger_ddl = '1';

revoke execute on function public.resolve_item_price(text, text, numeric, date) from anon, authenticated;
revoke execute on function public.resolve_item_price(text, text, numeric, date, uuid) from anon, authenticated;

do $$
declare
  v_default_wh uuid;
begin
  if to_regclass('public.orders') is not null then
    begin
      select public._resolve_default_warehouse_id() into v_default_wh;
    exception when others then
      v_default_wh := null;
    end;
    update public.orders
    set warehouse_id = coalesce(
      warehouse_id,
      case
        when (data->>'warehouseId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (data->>'warehouseId')::uuid
        else null
      end,
      v_default_wh
    )
    where warehouse_id is null;

    if exists (select 1 from public.orders where warehouse_id is null) then
      raise exception 'orders.warehouse_id has NULL rows; cannot enforce NOT NULL safely';
    end if;

    alter table public.orders
      alter column warehouse_id set not null;
  end if;
end $$;

create or replace function public.trg_orders_lock_warehouse_after_items()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_items_old jsonb;
  v_new_count int := 0;
  v_old_count int := 0;
begin
  v_items := coalesce(new.items, new.data->'items', '[]'::jsonb);
  v_items_old := coalesce(old.items, old.data->'items', '[]'::jsonb);
  if jsonb_typeof(v_items) = 'array' then
    v_new_count := jsonb_array_length(v_items);
  end if;
  if jsonb_typeof(v_items_old) = 'array' then
    v_old_count := jsonb_array_length(v_items_old);
  end if;
  if new.warehouse_id is distinct from old.warehouse_id and (v_new_count > 0 or v_old_count > 0) then
    raise exception 'Cannot change warehouse after adding items';
  end if;
  return new;
end;
$$;

do $$
begin
  if to_regclass('public.orders') is not null then
    drop trigger if exists trg_orders_lock_warehouse_after_items on public.orders;
    create trigger trg_orders_lock_warehouse_after_items
    before update on public.orders
    for each row
    execute function public.trg_orders_lock_warehouse_after_items();
  end if;
end $$;

notify pgrst, 'reload schema';
