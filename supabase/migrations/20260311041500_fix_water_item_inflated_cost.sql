-- ═══════════════════════════════════════════════════════════════
-- FIX: Repair item efa91e13 (ماء طيبة صغير 12*750ملي)
--
-- Root cause: Migration 20260228233500 broke receive_purchase_order_partial
-- by removing FX conversion and idempotency between Feb 28 – Mar 9.
--
-- Phase 1: Fix batch 36d60fe3 inflated cost (2900 SAR → correct SAR)
-- Phase 2: Fix any other inflated batches for this item
-- Phase 3: Fix inventory_movements with inflated costs
-- Phase 4: Recalculate avg_cost in stock_management
-- Phase 5: Fix journal_lines for affected movements
-- Phase 6: Archive empty batches (remaining = 0)
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_item_id constant text := 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a';
  v_po_fx_rate numeric;
  v_po_currency text;
  v_correct_cost numeric;
  v_wh uuid;
  v_total_qty numeric;
  v_weighted_cost numeric;
  v_new_avg numeric;
  v_batch record;
  v_move record;
  v_fixed_batches int := 0;
  v_fixed_movements int := 0;
  v_fixed_journals int := 0;
  v_archived_batches int := 0;
begin
  raise notice '=== Starting repair for item % ===', v_item_id;

  -- ── Get the PO FX rate ──
  select po.fx_rate, po.currency
  into v_po_fx_rate, v_po_currency
  from public.purchase_items pi
  join public.purchase_orders po on po.id = pi.purchase_order_id
  where pi.item_id::text = v_item_id
  limit 1;

  raise notice 'PO currency: %, FX rate: %', v_po_currency, v_po_fx_rate;

  -- If no FX rate or SAR, use median cost of all batches as reference
  if v_po_fx_rate is null or v_po_fx_rate <= 0 or v_po_fx_rate = 1 then
    -- Fallback: use median cost of normal-priced batches
    select percentile_cont(0.5) within group (order by b.unit_cost)
    into v_correct_cost
    from public.batches b
    where b.item_id::text = v_item_id
      and b.unit_cost < 100;  -- Only normal-priced batches

    raise notice 'No FX rate found, using median cost: %', v_correct_cost;
  else
    v_correct_cost := null; -- Will be calculated per batch
  end if;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 1 & 2: Fix ALL inflated batches
  -- A batch is "inflated" if its unit_cost > 100 SAR for this item
  -- (normal cost is ~6.776 SAR)
  -- ══════════════════════════════════════════════════════════════
  for v_batch in
    select b.id, b.unit_cost, b.foreign_unit_cost, b.fx_rate_at_receipt,
           b.foreign_currency, b.quantity_received, b.receipt_id
    from public.batches b
    where b.item_id::text = v_item_id
      and b.unit_cost > 100
    for update
  loop
    -- Calculate correct cost
    if v_batch.fx_rate_at_receipt is not null and v_batch.fx_rate_at_receipt > 0 then
      -- Use batch's own FX rate
      v_correct_cost := v_batch.unit_cost / v_batch.fx_rate_at_receipt;
    elsif v_po_fx_rate is not null and v_po_fx_rate > 1 then
      -- Use PO FX rate
      v_correct_cost := v_batch.unit_cost / v_po_fx_rate;
    else
      -- Fallback: median of normal batches
      select percentile_cont(0.5) within group (order by b2.unit_cost)
      into v_correct_cost
      from public.batches b2
      where b2.item_id::text = v_item_id and b2.unit_cost < 100;
    end if;

    raise notice 'Fixing batch %: % → % SAR (fx_rate=%, foreign=%)',
      left(v_batch.id::text, 8), v_batch.unit_cost, round(v_correct_cost, 3),
      coalesce(v_batch.fx_rate_at_receipt, v_po_fx_rate),
      v_batch.foreign_unit_cost;

    update public.batches
    set unit_cost = v_correct_cost,
        foreign_unit_cost = coalesce(foreign_unit_cost, v_batch.unit_cost),
        fx_rate_at_receipt = coalesce(fx_rate_at_receipt, v_po_fx_rate),
        updated_at = now()
    where id = v_batch.id;

    v_fixed_batches := v_fixed_batches + 1;

    -- Also fix the purchase_receipt_items for this batch's receipt
    update public.purchase_receipt_items
    set unit_cost = v_correct_cost,
        total_cost = quantity * v_correct_cost
    where receipt_id = v_batch.receipt_id
      and item_id::text = v_item_id
      and unit_cost > 100;
  end loop;

  raise notice 'Fixed % inflated batches', v_fixed_batches;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 3: Fix inflated inventory_movements
  -- ══════════════════════════════════════════════════════════════
  alter table public.inventory_movements disable trigger user;

  for v_move in
    select im.id, im.unit_cost, im.quantity, im.batch_id, im.movement_type
    from public.inventory_movements im
    where im.item_id::text = v_item_id
      and im.unit_cost > 100
    for update
  loop
    -- Get the corrected batch cost
    select b.unit_cost into v_correct_cost
    from public.batches b where b.id = v_move.batch_id;

    if v_correct_cost is null or v_correct_cost > 100 then
      -- Batch not found or still inflated, use median
      select percentile_cont(0.5) within group (order by b2.unit_cost)
      into v_correct_cost
      from public.batches b2
      where b2.item_id::text = v_item_id and b2.unit_cost < 100;
    end if;

    update public.inventory_movements
    set unit_cost = v_correct_cost,
        total_cost = v_move.quantity * v_correct_cost
    where id = v_move.id;

    v_fixed_movements := v_fixed_movements + 1;
  end loop;

  alter table public.inventory_movements enable trigger user;

  raise notice 'Fixed % inflated movements', v_fixed_movements;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 4: Recalculate avg_cost from all batches
  -- Weighted average: sum(qty_remaining * unit_cost) / sum(qty_remaining)
  -- ══════════════════════════════════════════════════════════════
  select
    coalesce(sum(greatest(0, b.quantity_received - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0))), 0),
    coalesce(sum(
      greatest(0, b.quantity_received - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0)) * b.unit_cost
    ), 0)
  into v_total_qty, v_weighted_cost
  from public.batches b
  where b.item_id::text = v_item_id
    and coalesce(b.status, 'active') = 'active';

  if v_total_qty > 0 then
    v_new_avg := v_weighted_cost / v_total_qty;
  else
    -- All consumed, use simple average
    select coalesce(avg(b.unit_cost), 0) into v_new_avg
    from public.batches b where b.item_id::text = v_item_id;
  end if;

  raise notice 'New avg_cost: % (from % remaining units, weighted cost %)',
    round(v_new_avg, 3), v_total_qty, round(v_weighted_cost, 3);

  -- Get warehouse
  select sm.warehouse_id into v_wh
  from public.stock_management sm
  where sm.item_id::text = v_item_id limit 1;

  update public.stock_management
  set avg_cost = v_new_avg,
      last_updated = now(), updated_at = now()
  where item_id::text = v_item_id;

  -- Also update menu_items.cost_price
  update public.menu_items
  set cost_price = v_new_avg, updated_at = now()
  where id::text = v_item_id;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 5: Fix journal_lines for affected movements
  -- ══════════════════════════════════════════════════════════════
  alter table public.journal_lines disable trigger user;

  update public.journal_lines jl
  set debit = case when jl.debit > 0 then public._money_round(im.total_cost) else 0 end,
      credit = case when jl.credit > 0 then public._money_round(im.total_cost) else 0 end,
      foreign_amount = case
        when jl.foreign_amount is not null and je.fx_rate is not null and je.fx_rate > 0
        then public._money_round(im.total_cost / je.fx_rate)
        else jl.foreign_amount
      end
  from public.journal_entries je
  join public.inventory_movements im on im.id::text = je.source_id
  where jl.journal_entry_id = je.id
    and je.source_table = 'inventory_movements'
    and im.item_id::text = v_item_id;

  get diagnostics v_fixed_journals = row_count;

  alter table public.journal_lines enable trigger user;

  raise notice 'Updated % journal lines', v_fixed_journals;

  -- ══════════════════════════════════════════════════════════════
  -- PHASE 6: Archive empty batches (remaining = 0, consumed = received)
  -- ══════════════════════════════════════════════════════════════
  update public.batches
  set status = 'archived', updated_at = now()
  where item_id::text = v_item_id
    and coalesce(status, 'active') = 'active'
    and (quantity_received - coalesce(quantity_consumed, 0) - coalesce(quantity_transferred, 0)) <= 0;

  get diagnostics v_archived_batches = row_count;

  -- Also remove their batch_balances
  delete from public.batch_balances
  where item_id::text = v_item_id
    and quantity <= 0;

  raise notice 'Archived % empty batches', v_archived_batches;

  -- ── Summary ──
  raise notice '=== REPAIR COMPLETE ===';
  raise notice 'Fixed batches: %', v_fixed_batches;
  raise notice 'Fixed movements: %', v_fixed_movements;
  raise notice 'Fixed journal lines: %', v_fixed_journals;
  raise notice 'Archived empty batches: %', v_archived_batches;
  raise notice 'New avg_cost: %', round(v_new_avg, 3);

  -- ── Audit log ──
  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
  values (
    'repair', 'inventory',
    format('Repaired item %s: fixed %s inflated batches, %s movements, %s journals, archived %s empty batches, new avg_cost=%s',
      v_item_id, v_fixed_batches, v_fixed_movements, v_fixed_journals, v_archived_batches, round(v_new_avg, 3)),
    auth.uid(), now(),
    jsonb_build_object('item_id', v_item_id, 'fixed_batches', v_fixed_batches,
      'fixed_movements', v_fixed_movements, 'archived', v_archived_batches, 'new_avg', v_new_avg)
  );
end $$;

notify pgrst, 'reload schema';
