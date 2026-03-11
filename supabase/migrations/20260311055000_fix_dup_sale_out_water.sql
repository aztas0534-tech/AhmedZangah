-- ═══════════════════════════════════════════════════════════════
-- FIX: Remove duplicate sale_out movements for item efa91e13
-- Same issue as duplicate return_in — some cancelled orders
-- had 2-3 sale_out movements instead of 1
--
-- Phase 1: Delete journal_lines for duplicate sale_out
-- Phase 2: Delete duplicate sale_out movements (keep oldest per order)
-- Phase 3: Recalculate batch quantity_consumed
-- Phase 4: Recalculate stock_management
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_item_id constant text := 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a';
  v_deleted_moves int := 0;
  v_deleted_jlines int := 0;
  v_batch record;
  v_consumed numeric;
  v_returned numeric;
  v_avail numeric;
  v_new_avg numeric;
  v_dup record;
begin
  raise notice '=== Cleaning duplicate sale_out for item % ===', v_item_id;

  -- Build list of duplicate sale_out IDs to remove
  create temp table _dup_saleout_ids as
  select im.id
  from public.inventory_movements im
  where im.item_id::text = v_item_id
    and im.movement_type = 'sale_out'
    and im.id not in (
      select distinct on (sub.reference_id)
        sub.id
      from public.inventory_movements sub
      where sub.item_id::text = v_item_id
        and sub.movement_type = 'sale_out'
      order by sub.reference_id, sub.occurred_at asc
    );

  -- Count duplicates
  select count(*) into v_deleted_moves from _dup_saleout_ids;
  raise notice 'Found % duplicate sale_out movements to remove', v_deleted_moves;

  if v_deleted_moves = 0 then
    raise notice 'No duplicates found, skipping';
    drop table _dup_saleout_ids;
    return;
  end if;

  -- Phase 1: Delete journal_lines for duplicate movements
  alter table public.journal_lines disable trigger user;

  delete from public.journal_lines jl
  where jl.journal_entry_id in (
    select je.id
    from public.journal_entries je
    where je.source_table = 'inventory_movements'
      and je.source_id::uuid in (select id from _dup_saleout_ids)
  );

  get diagnostics v_deleted_jlines = row_count;
  raise notice 'Deleted % journal lines', v_deleted_jlines;

  alter table public.journal_lines enable trigger user;

  -- Phase 2: Delete duplicate sale_out movements
  alter table public.inventory_movements disable trigger user;

  delete from public.inventory_movements
  where id in (select id from _dup_saleout_ids);

  alter table public.inventory_movements enable trigger user;

  raise notice 'Deleted % duplicate sale_out movements', v_deleted_moves;

  drop table _dup_saleout_ids;

  -- Phase 3: Recalculate batch quantity_consumed
  alter table public.batches disable trigger user;

  begin
    alter table public.batches drop constraint if exists batches_qty_consistency;
  exception when others then null;
  end;

  for v_batch in
    select b.id, b.quantity_received, b.quantity_consumed
    from public.batches b
    where b.item_id::text = v_item_id
    for update
  loop
    select coalesce(sum(im.quantity), 0)
    into v_consumed
    from public.inventory_movements im
    where im.batch_id = v_batch.id
      and im.movement_type in ('sale_out', 'wastage_out', 'adjust_out');

    select coalesce(sum(im.quantity), 0)
    into v_returned
    from public.inventory_movements im
    where im.batch_id = v_batch.id
      and im.movement_type in ('return_in', 'adjust_in');

    v_consumed := greatest(v_consumed - v_returned, 0);
    v_consumed := least(v_consumed, v_batch.quantity_received);

    if v_consumed <> coalesce(v_batch.quantity_consumed, 0) then
      raise notice 'Batch %: consumed % → %',
        left(v_batch.id::text, 8), v_batch.quantity_consumed, v_consumed;
    end if;

    update public.batches
    set quantity_consumed = v_consumed, updated_at = now()
    where id = v_batch.id;
  end loop;

  begin
    alter table public.batches add constraint batches_qty_consistency
      check (quantity_consumed <= quantity_received);
  exception when others then null;
  end;

  alter table public.batches enable trigger user;

  -- Phase 4: Recalculate stock_management
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

  update public.menu_items
  set cost_price = v_new_avg, updated_at = now()
  where id::text = v_item_id;

  raise notice '=== COMPLETE: available=%, avg_cost=% ===', v_avail, round(v_new_avg, 3);
end $$;

notify pgrst, 'reload schema';
