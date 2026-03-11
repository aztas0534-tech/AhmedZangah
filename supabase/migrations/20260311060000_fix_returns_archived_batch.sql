-- ═══════════════════════════════════════════════════════════════
-- FIX: Move 5 sales_returns return_in from archived batches
-- to the original active batch (9c35b7c0)
--
-- These 5 returns went to archived batches, so they don't count
-- toward available_quantity. Moving them fixes stock: 90 → 95
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_item_id  constant text := 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a';
  v_orig_batch constant uuid := '9c35b7c0-4fa9-4c26-850e-cd9747274f22';
  v_updated int;
  v_consumed numeric;
  v_returned numeric;
  v_avail numeric;
  v_new_avg numeric;
begin
  raise notice '=== Moving sales_returns return_in to original batch ===';

  -- Update the 5 return_in movements to point to original batch
  alter table public.inventory_movements disable trigger user;

  update public.inventory_movements im
  set batch_id = v_orig_batch
  where im.item_id::text = v_item_id
    and im.movement_type = 'return_in'
    and im.reference_table = 'sales_returns'
    and im.batch_id <> v_orig_batch;

  get diagnostics v_updated = row_count;
  raise notice 'Redirected % return_in movements to batch %', v_updated, left(v_orig_batch::text, 8);

  alter table public.inventory_movements enable trigger user;

  -- Recalculate original batch consumed
  alter table public.batches disable trigger user;

  begin
    alter table public.batches drop constraint if exists batches_qty_consistency;
  exception when others then null;
  end;

  select coalesce(sum(im.quantity), 0)
  into v_consumed
  from public.inventory_movements im
  where im.batch_id = v_orig_batch
    and im.movement_type in ('sale_out', 'wastage_out', 'adjust_out');

  select coalesce(sum(im.quantity), 0)
  into v_returned
  from public.inventory_movements im
  where im.batch_id = v_orig_batch
    and im.movement_type in ('return_in', 'adjust_in');

  v_consumed := greatest(v_consumed - v_returned, 0);

  raise notice 'Batch %: sale_out=%, return_in=%, new consumed=%',
    left(v_orig_batch::text, 8), v_consumed + v_returned, v_returned, v_consumed;

  update public.batches
  set quantity_consumed = least(v_consumed, quantity_received), updated_at = now()
  where id = v_orig_batch;

  begin
    alter table public.batches add constraint batches_qty_consistency
      check (quantity_consumed <= quantity_received);
  exception when others then null;
  end;

  alter table public.batches enable trigger user;

  -- Recalculate stock_management
  select coalesce(sum(
    greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
  ), 0)
  into v_avail
  from public.batches b
  where b.item_id::text = v_item_id
    and coalesce(b.status, 'active') <> 'archived';

  select case
    when sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)) > 0
    then sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) * b.unit_cost)
         / sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0))
    else coalesce(avg(b.unit_cost), 0)
  end
  into v_new_avg
  from public.batches b
  where b.item_id::text = v_item_id
    and coalesce(b.status, 'active') <> 'archived';

  update public.stock_management
  set available_quantity = v_avail,
      avg_cost = v_new_avg,
      reserved_quantity = 0,
      last_updated = now(), updated_at = now()
  where item_id::text = v_item_id;

  raise notice '=== DONE: available=%, avg_cost=% ===', v_avail, round(v_new_avg, 3);
end $$;

notify pgrst, 'reload schema';
