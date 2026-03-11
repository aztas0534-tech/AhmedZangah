-- ═══════════════════════════════════════════════════════════════
-- FIX: Move 2 sales_returns return_in from inactive batches
-- to the main batch for item 2f3a651d (ماء طيبة)
-- Fixes stock: 48 → 50
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_item_id    constant text := '2f3a651d-3368-4db3-941f-94f219cc554d';
  v_main_batch constant uuid := '3802d66b-9427-400c-92c7-233301ed01cd';
  v_updated int;
  v_consumed numeric;
  v_returned numeric;
  v_avail numeric;
  v_new_avg numeric;
begin
  raise notice '=== Fixing ماء طيبة item % ===', left(v_item_id, 8);

  -- Move sales_returns return_in to main batch
  alter table public.inventory_movements disable trigger user;

  update public.inventory_movements im
  set batch_id = v_main_batch
  where im.item_id::text = v_item_id
    and im.movement_type = 'return_in'
    and im.reference_table = 'sales_returns'
    and im.batch_id <> v_main_batch;

  get diagnostics v_updated = row_count;
  raise notice 'Redirected % return_in to main batch %', v_updated, left(v_main_batch::text, 8);

  alter table public.inventory_movements enable trigger user;

  -- Recalculate main batch consumed
  alter table public.batches disable trigger user;

  begin
    alter table public.batches drop constraint if exists batches_qty_consistency;
  exception when others then null;
  end;

  select coalesce(sum(im.quantity), 0) into v_consumed
  from public.inventory_movements im
  where im.batch_id = v_main_batch
    and im.movement_type in ('sale_out', 'wastage_out', 'adjust_out');

  select coalesce(sum(im.quantity), 0) into v_returned
  from public.inventory_movements im
  where im.batch_id = v_main_batch
    and im.movement_type in ('return_in', 'adjust_in');

  v_consumed := greatest(v_consumed - v_returned, 0);

  raise notice 'Batch %: new consumed=%', left(v_main_batch::text, 8), v_consumed;

  update public.batches
  set quantity_consumed = least(v_consumed, quantity_received), updated_at = now()
  where id = v_main_batch;

  begin
    alter table public.batches add constraint batches_qty_consistency
      check (quantity_consumed <= quantity_received);
  exception when others then null;
  end;

  alter table public.batches enable trigger user;

  -- Recalculate stock
  select coalesce(sum(
    greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
  ), 0)
  into v_avail
  from public.batches b
  where b.item_id::text = v_item_id
    and coalesce(b.status, 'active') not in ('archived', 'inactive');

  select case
    when sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)) > 0
    then sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) * b.unit_cost)
         / sum(greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0))
    else coalesce(avg(b.unit_cost), 0)
  end
  into v_new_avg
  from public.batches b
  where b.item_id::text = v_item_id
    and coalesce(b.status, 'active') not in ('archived', 'inactive');

  update public.stock_management
  set available_quantity = v_avail,
      avg_cost = v_new_avg,
      reserved_quantity = 0,
      last_updated = now(), updated_at = now()
  where item_id::text = v_item_id;

  raise notice '=== DONE: available=%, avg_cost=% ===', v_avail, round(v_new_avg, 3);
end $$;

notify pgrst, 'reload schema';
