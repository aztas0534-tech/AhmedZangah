-- ═══════════════════════════════════════════════════════════════
-- FIX: Remove duplicate return_in movements for item efa91e13
-- and recalculate batches + stock_management
--
-- Problem: Some cancelled orders had 2-3 return_in movements
-- instead of 1, inflating available_quantity.
--
-- Phase 1: Zero-out journal entries for duplicate movements (can't delete due to FK)
-- Phase 2: Delete duplicate return_in movements (keep oldest per order)
-- Phase 3: Recalculate batch quantity_consumed from movements
-- Phase 4: Recalculate stock_management.available_quantity
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_item_id constant text := 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a';
  v_deleted_moves int := 0;
  v_zeroed_journals int := 0;
  v_batch record;
  v_consumed numeric;
  v_returned numeric;
  v_avail numeric;
  v_new_avg numeric;
  v_dup record;
begin
  raise notice '=== Starting duplicate return_in cleanup for item % ===', v_item_id;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 1: Zero-out journal entries for duplicate movements
  -- ══════════════════════════════════════════════════════════════

  -- IDs of duplicate movements to remove (keep oldest per order)
  create temp table _dup_move_ids as
  select im.id
  from public.inventory_movements im
  where im.item_id::text = v_item_id
    and im.movement_type = 'return_in'
    and im.reference_table = 'orders'
    and im.id not in (
      select distinct on (sub.reference_id)
        sub.id
      from public.inventory_movements sub
      where sub.item_id::text = v_item_id
        and sub.movement_type = 'return_in'
        and sub.reference_table = 'orders'
      order by sub.reference_id, sub.occurred_at asc
    );

  -- Log duplicates
  for v_dup in
    select im.reference_id, count(*) as cnt
    from public.inventory_movements im
    where im.item_id::text = v_item_id
      and im.movement_type = 'return_in'
      and im.reference_table = 'orders'
    group by im.reference_id
    having count(*) > 1
  loop
    raise notice 'Duplicate for order %: % entries (keeping 1)',
      left(v_dup.reference_id, 8), v_dup.cnt;
  end loop;

  -- Delete journal lines for duplicate movements (leave journal_entries as orphans)
  alter table public.journal_lines disable trigger user;

  delete from public.journal_lines jl
  where jl.journal_entry_id in (
    select je.id
    from public.journal_entries je
    where je.source_table = 'inventory_movements'
      and je.source_id::uuid in (select id from _dup_move_ids)
  );

  get diagnostics v_zeroed_journals = row_count;
  raise notice 'Deleted % journal lines for duplicate movements', v_zeroed_journals;

  alter table public.journal_lines enable trigger user;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 2: Delete duplicate return_in movements
  -- ══════════════════════════════════════════════════════════════
  alter table public.inventory_movements disable trigger user;

  delete from public.inventory_movements
  where id in (select id from _dup_move_ids);

  get diagnostics v_deleted_moves = row_count;
  raise notice 'Deleted % duplicate return_in movements', v_deleted_moves;

  alter table public.inventory_movements enable trigger user;

  drop table _dup_move_ids;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 3: Recalculate batch quantity_consumed
  -- ══════════════════════════════════════════════════════════════
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
    -- outgoing = sale_out + wastage_out + adjust_out
    select coalesce(sum(im.quantity), 0)
    into v_consumed
    from public.inventory_movements im
    where im.batch_id = v_batch.id
      and im.movement_type in ('sale_out', 'wastage_out', 'adjust_out');

    -- incoming returns = return_in + adjust_in (reduce consumption)
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

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 4: Recalculate stock_management
  -- ══════════════════════════════════════════════════════════════
  select coalesce(sum(
    greatest(b.quantity_received - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)
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

  raise notice 'Stock: available=%, avg_cost=%', v_avail, round(v_new_avg, 3);

  update public.stock_management
  set available_quantity = v_avail,
      avg_cost = v_new_avg,
      reserved_quantity = 0,
      last_updated = now(), updated_at = now()
  where item_id::text = v_item_id;

  update public.menu_items
  set cost_price = v_new_avg, updated_at = now()
  where id::text = v_item_id;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 5: Clean batch_balances
  -- ══════════════════════════════════════════════════════════════
  begin
    delete from public.batch_balances
    where item_id::text = v_item_id
      and batch_id in (
        select b.id from public.batches b
        where b.item_id::text = v_item_id
          and (b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0)) <= 0
      );

    update public.batch_balances bb
    set quantity = greatest(b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
    from public.batches b
    where bb.batch_id = b.id
      and bb.item_id::text = v_item_id
      and (b.quantity_received - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0)) > 0;
  exception when others then
    raise notice 'batch_balances update skipped (table may not exist)';
  end;

  raise notice '=== CLEANUP COMPLETE ===';
  raise notice 'Deleted % duplicate return_in, zeroed % journal lines', v_deleted_moves, v_zeroed_journals;
  raise notice 'New available=%  avg_cost=%', v_avail, round(v_new_avg, 3);
end $$;

notify pgrst, 'reload schema';
