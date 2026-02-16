-- Auto-populate supplier_items from purchase orders
-- 1. Trigger: on purchase_items INSERT, upsert into supplier_items
-- 2. Backfill: populate from all historical purchase_items

-- ─── Trigger function ───────────────────────────────────────────────
create or replace function public.trg_upsert_supplier_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_supplier_id uuid;
begin
  -- Get supplier_id from the parent purchase order
  select po.supplier_id into v_supplier_id
  from public.purchase_orders po
  where po.id = NEW.purchase_order_id;

  -- Only proceed if we have both supplier and item
  if v_supplier_id is not null and NEW.item_id is not null then
    insert into public.supplier_items (supplier_id, item_id, is_active)
    values (v_supplier_id, NEW.item_id, true)
    on conflict (supplier_id, item_id) do update
      set updated_at = now();
  end if;

  return NEW;
end;
$$;

-- ─── Attach trigger ─────────────────────────────────────────────────
drop trigger if exists trg_purchase_item_upsert_supplier on public.purchase_items;

create trigger trg_purchase_item_upsert_supplier
  after insert on public.purchase_items
  for each row
  execute function public.trg_upsert_supplier_item();

-- ─── Backfill from historical data ─────────────────────────────────
insert into public.supplier_items (supplier_id, item_id, is_active, created_at, updated_at)
select distinct
  po.supplier_id,
  pi.item_id,
  true,
  min(pi.created_at),
  max(pi.created_at)
from public.purchase_items pi
join public.purchase_orders po on po.id = pi.purchase_order_id
where po.supplier_id is not null
  and pi.item_id is not null
group by po.supplier_id, pi.item_id
on conflict (supplier_id, item_id) do update
  set updated_at = greatest(supplier_items.updated_at, excluded.updated_at);

-- ─── Verify ─────────────────────────────────────────────────────────
do $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.supplier_items;
  raise notice 'supplier_items populated: % rows', v_count;
end $$;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
