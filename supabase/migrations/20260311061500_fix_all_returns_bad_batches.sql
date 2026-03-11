-- ═══════════════════════════════════════════════════════════════
-- FIX: System-wide fix for return_in movements pointing to
-- archived/inactive batches (quantity_received=0)
--
-- These returns don't count toward available_quantity because
-- they reference batches that are excluded from stock calculation.
--
-- Strategy: For each affected item, redirect return_in movements
-- to the main active batch (largest quantity_received), then
-- recalculate consumed and stock.
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_item record;
  v_main_batch_id uuid;
  v_updated int;
  v_consumed numeric;
  v_returned numeric;
  v_avail numeric;
  v_new_avg numeric;
  v_total_fixed int := 0;
  v_total_items int := 0;
begin
  raise notice '=== SYSTEM-WIDE: Fixing return_in in bad batches ===';

  alter table public.inventory_movements disable trigger user;
  alter table public.batches disable trigger user;

  begin
    alter table public.batches drop constraint if exists batches_qty_consistency;
  exception when others then null;
  end;

  -- Find all items with return_in pointing to bad batches
  for v_item in
    select distinct im.item_id
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    where im.movement_type = 'return_in'
      and (b.status in ('archived', 'inactive') or b.quantity_received = 0)
  loop
    -- Find the main active batch for this item (largest received)
    select b.id into v_main_batch_id
    from public.batches b
    where b.item_id = v_item.item_id
      and b.status = 'active'
      and b.quantity_received > 0
    order by b.quantity_received desc, b.created_at asc
    limit 1;

    if v_main_batch_id is null then
      raise notice 'SKIP item %: no active batch found', left(v_item.item_id::text, 8);
      continue;
    end if;

    -- Redirect return_in from bad batches to main batch
    update public.inventory_movements im
    set batch_id = v_main_batch_id
    from public.batches b
    where im.batch_id = b.id
      and im.item_id = v_item.item_id
      and im.movement_type = 'return_in'
      and (b.status in ('archived', 'inactive') or b.quantity_received = 0);

    get diagnostics v_updated = row_count;
    v_total_fixed := v_total_fixed + v_updated;
    v_total_items := v_total_items + 1;

    raise notice 'Item %: redirected % return_in to batch %',
      left(v_item.item_id::text, 8), v_updated, left(v_main_batch_id::text, 8);

    -- Recalculate consumed for the main batch
    select coalesce(sum(im.quantity), 0) into v_consumed
    from public.inventory_movements im
    where im.batch_id = v_main_batch_id
      and im.movement_type in ('sale_out', 'wastage_out', 'adjust_out');

    select coalesce(sum(im.quantity), 0) into v_returned
    from public.inventory_movements im
    where im.batch_id = v_main_batch_id
      and im.movement_type in ('return_in', 'adjust_in');

    v_consumed := greatest(v_consumed - v_returned, 0);

    update public.batches
    set quantity_consumed = least(v_consumed, quantity_received), updated_at = now()
    where id = v_main_batch_id;

    -- Recalculate stock_management for this item
    select coalesce(sum(
      greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
    ), 0)
    into v_avail
    from public.batches b
    where b.item_id = v_item.item_id
      and b.status = 'active';

    select case
      when sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)) > 0
      then sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) * b.unit_cost)
           / sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0))
      else coalesce(avg(b.unit_cost), 0)
    end
    into v_new_avg
    from public.batches b
    where b.item_id = v_item.item_id
      and b.status = 'active';

    update public.stock_management
    set available_quantity = v_avail,
        avg_cost = coalesce(v_new_avg, avg_cost),
        last_updated = now(), updated_at = now()
    where item_id = v_item.item_id;

  end loop;

  begin
    alter table public.batches add constraint batches_qty_consistency
      check (quantity_consumed <= quantity_received);
  exception when others then null;
  end;

  alter table public.batches enable trigger user;
  alter table public.inventory_movements enable trigger user;

  raise notice '=== COMPLETE: Fixed % items, redirected % return_in movements ===',
    v_total_items, v_total_fixed;
end $$;

notify pgrst, 'reload schema';
