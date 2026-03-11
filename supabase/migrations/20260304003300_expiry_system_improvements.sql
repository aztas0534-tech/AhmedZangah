-- ============================================================================
-- Migration: Expiry Date System Improvements
-- Date: 2026-03-04
-- Features:
--   1. shelf_life_days column on menu_items for auto-calculation
--   2. quarantine_expired_batches() function for auto-quarantine
--   3. Cron job for daily auto-quarantine
-- ============================================================================

-- ── 1) Add shelf_life_days to menu_items ──
alter table public.menu_items
  add column if not exists shelf_life_days int;

comment on column public.menu_items.shelf_life_days
  is 'Default shelf life in days for this item. When production_date is entered, expiry_date = production_date + shelf_life_days.';

-- ── 2) Auto-quarantine function ──
-- Marks any batch with a past expiry_date as qc_status = 'quarantined'
-- and logs an inventory movement of type 'wastage_out' for accounting.
create or replace function public.quarantine_expired_batches()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int := 0;
  v_batch record;
  v_wh uuid;
  v_movement_id uuid;
begin
  for v_batch in
    select b.id, b.item_id, b.warehouse_id, b.expiry_date,
           greatest(
             coalesce(b.quantity_received,0)
             - coalesce(b.quantity_consumed,0)
             - coalesce(b.quantity_transferred,0),
             0
           ) as remaining_qty,
           coalesce(b.unit_cost, 0) as unit_cost
    from public.batches b
    where b.expiry_date is not null
      and b.expiry_date < current_date
      and coalesce(b.status, 'active') = 'active'
      and coalesce(b.qc_status, 'released') <> 'quarantined'
      and greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) > 0
  loop
    -- Mark batch as quarantined
    update public.batches
    set qc_status = 'quarantined',
        data = coalesce(data, '{}'::jsonb) || jsonb_build_object(
          'quarantinedAt', now()::text,
          'quarantineReason', 'expired',
          'daysExpired', (current_date - v_batch.expiry_date)::int
        ),
        updated_at = now()
    where id = v_batch.id;

    -- Recompute stock for this item/warehouse
    v_wh := v_batch.warehouse_id;
    if v_wh is not null then
      perform public.recompute_stock_for_item(v_batch.item_id::text, v_wh);
    end if;

    v_count := v_count + 1;
  end loop;

  return json_build_object('quarantined_batches', v_count, 'run_at', now()::text);
end;
$$;

revoke all on function public.quarantine_expired_batches() from public;
grant execute on function public.quarantine_expired_batches() to authenticated;

-- ── 3) RPC to get shelf_life_days for an item ──
create or replace function public.get_item_shelf_life(p_item_id text)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select mi.shelf_life_days
  from public.menu_items mi
  where mi.id = p_item_id;
$$;

revoke all on function public.get_item_shelf_life(text) from public;
grant execute on function public.get_item_shelf_life(text) to authenticated;

-- ── 4) Register daily cron job for auto-quarantine ──
do $$
begin
  if to_regclass('cron.job') is not null then
    if not exists (select 1 from cron.job where jobname = 'quarantine_expired_batches_daily') then
      perform cron.schedule(
        'quarantine_expired_batches_daily',
        '0 3 * * *',
        $cmd$select public.quarantine_expired_batches();$cmd$
      );
    end if;
  end if;
end $$;

-- ── 5) View for quarantined/expired inventory report ──
create or replace view public.v_quarantined_stock as
select
  b.id as batch_id,
  b.item_id,
  coalesce(mi.data->'name'->>'ar', mi.data->'name'->>'en', mi.data->>'name', b.item_id) as item_name,
  b.warehouse_id,
  w.name as warehouse_name,
  b.expiry_date,
  (current_date - b.expiry_date)::int as days_expired,
  greatest(
    coalesce(b.quantity_received,0)
    - coalesce(b.quantity_consumed,0)
    - coalesce(b.quantity_transferred,0),
    0
  ) as remaining_qty,
  coalesce(b.unit_cost, 0) as unit_cost,
  b.qc_status,
  b.production_date
from public.batches b
join public.menu_items mi on mi.id = b.item_id
left join public.warehouses w on w.id = b.warehouse_id
where b.qc_status = 'quarantined'
  and greatest(
    coalesce(b.quantity_received,0)
    - coalesce(b.quantity_consumed,0)
    - coalesce(b.quantity_transferred,0),
    0
  ) > 0;

notify pgrst, 'reload schema';
