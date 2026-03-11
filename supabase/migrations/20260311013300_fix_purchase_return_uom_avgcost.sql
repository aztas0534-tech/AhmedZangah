-- ═══════════════════════════════════════════════════════════════
-- Fix create_purchase_return:
--   1) Convert return qty to base UOM via item_qty_to_base()
--   2) Recalculate avg_cost after return deduction
--   3) Use base_unit instead of unit_type for stock_management
--   4) Use batch unit_cost for return_item_total (already per-base, base-currency)
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

create or replace function public.create_purchase_return(
  p_order_id uuid,
  p_items jsonb,
  p_reason text default null,
  p_occurred_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po record;
  v_item jsonb;
  v_item_id_text text;
  v_item_id_uuid uuid;
  v_req_batch_text text;
  v_req_batch_id uuid;
  v_qty numeric;
  v_qty_base numeric;                    -- NEW: quantity in base UOM
  v_uom_id uuid;                         -- NEW: UOM id from item
  v_uom_code text;                       -- NEW: UOM code from JSON
  v_po_unit_cost numeric;
  v_stock_available numeric;
  v_stock_reserved numeric;
  v_stock_avg_cost numeric;
  v_return_item_total numeric;
  v_return_total numeric := 0;
  v_new_total numeric;
  v_return_id uuid;
  v_movement_id uuid;
  v_stock_item_id_is_uuid boolean;
  v_return_items_item_id_is_uuid boolean;
  v_inventory_movements_item_id_is_uuid boolean;
  v_inventory_movements_reference_id_is_uuid boolean;
  v_has_sm_warehouse boolean := false;
  v_has_im_batch boolean := false;
  v_has_im_warehouse boolean := false;
  v_has_bb boolean := false;
  v_has_bb_warehouse boolean := false;
  v_wh uuid;
  v_received_qty numeric;
  v_prev_returned numeric;
  v_needed numeric;
  v_take numeric;
  v_batch record;
  v_batch_unit_cost numeric;
  v_req_remaining numeric;
  v_qr numeric;
  v_qc numeric;
  v_old_qty numeric;                     -- NEW: for avg_cost recalc
  v_old_avg numeric;                     -- NEW: for avg_cost recalc
  v_new_qty numeric;                     -- NEW: for avg_cost recalc
  v_deducted_cost numeric;               -- NEW: total cost deducted from batches
  v_new_avg numeric;                     -- NEW: recalculated avg_cost
begin
  if not public.can_manage_stock() then
    raise exception 'not allowed';
  end if;
  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;
  if not exists (
    select 1
    from jsonb_array_elements(p_items) e
    where coalesce(nullif(e.value->>'quantity', '')::numeric, 0) > 0
  ) then
    raise exception 'no return items';
  end if;

  -- ── Schema introspection (preserved from original) ──
  v_has_sm_warehouse := exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stock_management' and column_name = 'warehouse_id'
  );
  v_has_bb := to_regclass('public.batch_balances') is not null;
  if v_has_bb then
    v_has_bb_warehouse := exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'batch_balances' and column_name = 'warehouse_id'
    );
  end if;
  v_has_im_batch := exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'inventory_movements' and column_name = 'batch_id'
  );
  v_has_im_warehouse := exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'inventory_movements' and column_name = 'warehouse_id'
  );

  select (t.typname = 'uuid')
  into v_stock_item_id_is_uuid
  from pg_attribute a
  join pg_class c on a.attrelid = c.oid
  join pg_namespace n on c.relnamespace = n.oid
  join pg_type t on a.atttypid = t.oid
  where n.nspname = 'public' and c.relname = 'stock_management'
    and a.attname = 'item_id' and a.attnum > 0 and not a.attisdropped;

  select (t.typname = 'uuid')
  into v_return_items_item_id_is_uuid
  from pg_attribute a
  join pg_class c on a.attrelid = c.oid
  join pg_namespace n on c.relnamespace = n.oid
  join pg_type t on a.atttypid = t.oid
  where n.nspname = 'public' and c.relname = 'purchase_return_items'
    and a.attname = 'item_id' and a.attnum > 0 and not a.attisdropped;

  select (t.typname = 'uuid')
  into v_inventory_movements_item_id_is_uuid
  from pg_attribute a
  join pg_class c on a.attrelid = c.oid
  join pg_namespace n on c.relnamespace = n.oid
  join pg_type t on a.atttypid = t.oid
  where n.nspname = 'public' and c.relname = 'inventory_movements'
    and a.attname = 'item_id' and a.attnum > 0 and not a.attisdropped;

  select (t.typname = 'uuid')
  into v_inventory_movements_reference_id_is_uuid
  from pg_attribute a
  join pg_class c on a.attrelid = c.oid
  join pg_namespace n on c.relnamespace = n.oid
  join pg_type t on a.atttypid = t.oid
  where n.nspname = 'public' and c.relname = 'inventory_movements'
    and a.attname = 'reference_id' and a.attnum > 0 and not a.attisdropped;

  -- ── Lock purchase order ──
  select *
  into v_po
  from public.purchase_orders
  where id = p_order_id
  for update;
  if not found then
    raise exception 'purchase order not found';
  end if;
  if v_po.status = 'cancelled' then
    raise exception 'cannot return for cancelled purchase order';
  end if;

  -- ── Resolve warehouse ──
  if v_has_sm_warehouse then
    v_wh := coalesce(v_po.warehouse_id, public._resolve_default_warehouse_id());
    if v_wh is null then
      raise exception 'warehouse_id is required';
    end if;
  else
    v_wh := null;
  end if;

  -- ── Create purchase_returns header ──
  insert into public.purchase_returns(purchase_order_id, returned_at, created_by, reason)
  values (p_order_id, coalesce(p_occurred_at, now()), auth.uid(), nullif(trim(coalesce(p_reason, '')), ''))
  returning id into v_return_id;

  -- ══════════════════════════════════════════════════════════════
  -- ITEM LOOP
  -- ══════════════════════════════════════════════════════════════
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_item_id_text := coalesce(v_item->>'itemId', v_item->>'id');
    v_qty := coalesce(nullif(v_item->>'quantity', '')::numeric, 0);
    v_req_batch_text := nullif(trim(coalesce(v_item->>'batchId', '')), '');
    v_req_batch_id := null;
    if v_req_batch_text is not null then
      begin
        v_req_batch_id := v_req_batch_text::uuid;
      exception when others then
        raise exception 'Invalid batchId %', v_req_batch_text;
      end;
    end if;
    if v_item_id_text is null or v_item_id_text = '' then
      raise exception 'Invalid itemId';
    end if;
    if v_qty <= 0 then
      continue;
    end if;

    -- ── FIX #1: Convert return qty to base UOM ──
    v_uom_id := null;
    v_uom_code := null;
    begin
      v_uom_code := nullif(btrim(coalesce(
        v_item->>'uomCode', v_item->>'uom_code', v_item->>'uom', v_item->>'unit', v_item->>'unitType'
      )), '');
    exception when others then null;
    end;
    begin
      v_uom_id := nullif(coalesce(v_item->>'uomId', v_item->>'uom_id'), '')::uuid;
    exception when others then v_uom_id := null;
    end;
    -- Resolve UOM from code if no ID
    if v_uom_id is null and v_uom_code is not null then
      begin
        v_uom_id := public.ensure_uom_code(v_uom_code, null);
      exception when others then v_uom_id := null;
      end;
    end if;
    -- Fallback: use item's base UOM from item_uom table
    if v_uom_id is null then
      select iu.base_uom_id into v_uom_id
      from public.item_uom iu where iu.item_id = v_item_id_text limit 1;
    end if;
    -- Convert to base quantity
    v_qty_base := public.item_qty_to_base(v_item_id_text, v_qty, v_uom_id);

    -- Cast item_id to uuid if needed
    if coalesce(v_stock_item_id_is_uuid, false)
      or coalesce(v_return_items_item_id_is_uuid, false)
      or coalesce(v_inventory_movements_item_id_is_uuid, false)
    then
      begin
        v_item_id_uuid := v_item_id_text::uuid;
      exception when others then
        raise exception 'Invalid itemId %', v_item_id_text;
      end;
    end if;

    -- ── Validate: return does not exceed received ──
    select coalesce(sum(pi.received_quantity), 0), coalesce(max(pi.unit_cost), 0)
    into v_received_qty, v_po_unit_cost
    from public.purchase_items pi
    where pi.purchase_order_id = p_order_id
      and pi.item_id::text = v_item_id_text;

    if not found then
      raise exception 'item % not found in purchase order', v_item_id_text;
    end if;

    select coalesce(sum(pri.quantity), 0)
    into v_prev_returned
    from public.purchase_returns pr
    join public.purchase_return_items pri on pri.return_id = pr.id
    where pr.purchase_order_id = p_order_id
      and pri.item_id::text = v_item_id_text;

    if (coalesce(v_prev_returned, 0) + v_qty_base) > (coalesce(v_received_qty, 0) + 1e-9) then
      raise exception 'return exceeds received for item %', v_item_id_text;
    end if;

    -- ── Ensure stock_management row exists ──
    if v_has_sm_warehouse then
      -- FIX #3: Use base_unit instead of unit_type
      insert into public.stock_management(item_id, warehouse_id, available_quantity, reserved_quantity, unit, low_stock_threshold, last_updated, data)
      select v_item_id_text, v_wh, 0, 0, coalesce(mi.base_unit, mi.unit_type, 'piece'), 5, now(), '{}'::jsonb
      from public.menu_items mi where mi.id::text = v_item_id_text
      on conflict (item_id, warehouse_id) do nothing;

      select
        coalesce(sm.available_quantity, 0),
        coalesce(sm.reserved_quantity, 0),
        coalesce(sm.avg_cost, 0)
      into v_stock_available, v_stock_reserved, v_stock_avg_cost
      from public.stock_management sm
      where sm.item_id::text = v_item_id_text
        and sm.warehouse_id = v_wh
      for update;
    else
      insert into public.stock_management(item_id, available_quantity, reserved_quantity, unit, low_stock_threshold, last_updated, data)
      select v_item_id_text, 0, 0, coalesce(mi.base_unit, mi.unit_type, 'piece'), 5, now(), '{}'::jsonb
      from public.menu_items mi where mi.id::text = v_item_id_text
      on conflict (item_id) do nothing;

      select
        coalesce(sm.available_quantity, 0),
        coalesce(sm.reserved_quantity, 0),
        coalesce(sm.avg_cost, 0)
      into v_stock_available, v_stock_reserved, v_stock_avg_cost
      from public.stock_management sm
      where sm.item_id::text = v_item_id_text
      for update;
    end if;

    if not found then
      raise exception 'Stock record not found for item %', v_item_id_text;
    end if;

    -- ── Validate sufficient stock ──
    if (coalesce(v_stock_available, 0) - coalesce(v_stock_reserved, 0) + 1e-9) < v_qty_base then
      raise exception 'insufficient stock for return for item %', v_item_id_text;
    end if;

    -- ── Deduct stock ──
    if v_has_sm_warehouse then
      update public.stock_management
      set available_quantity = available_quantity - v_qty_base,
          last_updated = now(), updated_at = now()
      where item_id::text = v_item_id_text and warehouse_id = v_wh;
    else
      update public.stock_management
      set available_quantity = available_quantity - v_qty_base,
          last_updated = now(), updated_at = now()
      where item_id::text = v_item_id_text;
    end if;

    -- ── Insert purchase_return_items (use batch cost later, fallback to avg_cost) ──
    -- Initial insert with PO unit_cost; will be corrected by recompute_purchase_return_item_costs trigger
    v_return_item_total := v_qty_base * coalesce(v_stock_avg_cost, v_po_unit_cost, 0);
    v_return_total := v_return_total + v_return_item_total;

    if coalesce(v_return_items_item_id_is_uuid, false) then
      insert into public.purchase_return_items(return_id, item_id, quantity, unit_cost, total_cost)
      values (v_return_id, v_item_id_uuid, v_qty_base, coalesce(v_stock_avg_cost, v_po_unit_cost, 0), v_return_item_total);
    else
      insert into public.purchase_return_items(return_id, item_id, quantity, unit_cost, total_cost)
      values (v_return_id, v_item_id_text, v_qty_base, coalesce(v_stock_avg_cost, v_po_unit_cost, 0), v_return_item_total);
    end if;

    if coalesce(v_stock_avg_cost, 0) <= 0 then
      v_stock_avg_cost := coalesce(v_po_unit_cost, 0);
    end if;

    -- ── Track total deducted cost for avg_cost recalculation ──
    v_deducted_cost := 0;
    v_needed := v_qty_base;

    -- ══════════════════════════════════════════════════════════
    -- BATCH-AWARE PATH
    -- ══════════════════════════════════════════════════════════
    if v_has_bb and v_has_bb_warehouse and v_has_im_batch and v_has_im_warehouse then
      if v_req_batch_id is not null then
        -- Specific batch requested
        select
          coalesce(bb.quantity, 0) as qty,
          b.unit_cost as unit_cost
        into v_req_remaining, v_batch_unit_cost
        from public.batch_balances bb
        join public.batches b on b.id = bb.batch_id
        join public.purchase_receipts pr on pr.id = b.receipt_id
        where bb.item_id::text = v_item_id_text
          and bb.warehouse_id = v_wh
          and bb.batch_id = v_req_batch_id
          and coalesce(bb.quantity, 0) > 0
          and b.item_id::text = v_item_id_text
          and b.warehouse_id = v_wh
          and coalesce(b.status,'active') = 'active'
          and pr.purchase_order_id = p_order_id
        for update;

        if not found then
          raise exception 'batch % not available for return for item %', v_req_batch_id, v_item_id_text;
        end if;
        if coalesce(v_req_remaining, 0) <= 0 then
          raise exception 'insufficient batch stock for return for item %', v_item_id_text;
        end if;

        v_take := least(v_needed, coalesce(v_req_remaining, 0));
        update public.batch_balances
        set quantity = quantity - v_take, updated_at = now()
        where item_id::text = v_item_id_text and batch_id = v_req_batch_id and warehouse_id = v_wh;

        update public.batches
        set quantity_consumed = coalesce(quantity_consumed, 0) + v_take, updated_at = now()
        where id = v_req_batch_id and item_id::text = v_item_id_text and warehouse_id = v_wh
        returning quantity_received, quantity_consumed into v_qr, v_qc;

        if coalesce(v_qc, 0) > (coalesce(v_qr, 0) + 1e-9) then
          raise exception 'Over-consumption detected for batch %', v_req_batch_id;
        end if;

        v_batch_unit_cost := coalesce(v_batch_unit_cost, v_stock_avg_cost, coalesce(v_po_unit_cost, 0), 0);
        v_deducted_cost := v_deducted_cost + (v_take * v_batch_unit_cost);

        insert into public.inventory_movements(
          item_id, movement_type, quantity, unit_cost, total_cost,
          reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
        ) values (
          v_item_id_text, 'return_out', v_take, v_batch_unit_cost, (v_take * v_batch_unit_cost),
          'purchase_returns', v_return_id::text, coalesce(p_occurred_at, now()), auth.uid(),
          jsonb_build_object('purchaseOrderId', p_order_id, 'purchaseReturnId', v_return_id::text, 'warehouseId', v_wh::text, 'batchId', v_req_batch_id::text),
          v_req_batch_id, v_wh
        ) returning id into v_movement_id;

        perform public.post_inventory_movement(v_movement_id);
        v_needed := v_needed - v_take;

        if v_needed > 0.000000001 then
          raise exception 'insufficient batch stock for return for item %', v_item_id_text;
        end if;
      else
        -- FEFO: pick batches from this PO, nearest expiry first
        for v_batch in
          select bb.batch_id, coalesce(bb.quantity, 0) as qty, bb.expiry_date, b.unit_cost
          from public.batch_balances bb
          join public.batches b on b.id = bb.batch_id
          join public.purchase_receipts pr on pr.id = b.receipt_id
          where bb.item_id::text = v_item_id_text
            and bb.warehouse_id = v_wh
            and coalesce(bb.quantity, 0) > 0
            and b.item_id::text = v_item_id_text
            and b.warehouse_id = v_wh
            and coalesce(b.status,'active') = 'active'
            and pr.purchase_order_id = p_order_id
          order by (bb.expiry_date is null) asc, bb.expiry_date asc, bb.batch_id asc
          for update
        loop
          exit when v_needed <= 0;
          v_take := least(v_needed, coalesce(v_batch.qty, 0));
          if v_take <= 0 then continue; end if;

          update public.batch_balances
          set quantity = quantity - v_take, updated_at = now()
          where item_id::text = v_item_id_text and batch_id = v_batch.batch_id and warehouse_id = v_wh;

          update public.batches
          set quantity_consumed = coalesce(quantity_consumed, 0) + v_take, updated_at = now()
          where id = v_batch.batch_id and item_id::text = v_item_id_text and warehouse_id = v_wh
          returning quantity_received, quantity_consumed into v_qr, v_qc;

          if coalesce(v_qc, 0) > (coalesce(v_qr, 0) + 1e-9) then
            raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
          end if;

          v_batch_unit_cost := coalesce(v_batch.unit_cost, v_stock_avg_cost, coalesce(v_po_unit_cost, 0), 0);
          v_deducted_cost := v_deducted_cost + (v_take * v_batch_unit_cost);

          insert into public.inventory_movements(
            item_id, movement_type, quantity, unit_cost, total_cost,
            reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
          ) values (
            v_item_id_text, 'return_out', v_take, v_batch_unit_cost, (v_take * v_batch_unit_cost),
            'purchase_returns', v_return_id::text, coalesce(p_occurred_at, now()), auth.uid(),
            jsonb_build_object('purchaseOrderId', p_order_id, 'purchaseReturnId', v_return_id::text, 'warehouseId', v_wh::text, 'batchId', v_batch.batch_id::text),
            v_batch.batch_id, v_wh
          ) returning id into v_movement_id;

          perform public.post_inventory_movement(v_movement_id);
          v_needed := v_needed - v_take;
        end loop;

        if v_needed > 0.000000001 then
          raise exception 'insufficient batch stock for return for item %', v_item_id_text;
        end if;
      end if;
    else
      -- ══════════════════════════════════════════════════════════
      -- NON-BATCH PATH (legacy fallback)
      -- ══════════════════════════════════════════════════════════
      v_deducted_cost := v_qty_base * v_stock_avg_cost;

      insert into public.inventory_movements(
        item_id, movement_type, quantity, unit_cost, total_cost,
        reference_table, reference_id, occurred_at, created_by, data, warehouse_id
      ) values (
        v_item_id_text, 'return_out', v_qty_base, v_stock_avg_cost, (v_qty_base * v_stock_avg_cost),
        'purchase_returns', v_return_id::text, coalesce(p_occurred_at, now()), auth.uid(),
        jsonb_build_object('purchaseOrderId', p_order_id, 'purchaseReturnId', v_return_id::text, 'warehouseId', coalesce(v_wh::text, '')),
        v_wh
      ) returning id into v_movement_id;

      perform public.post_inventory_movement(v_movement_id);
    end if;

    -- ══════════════════════════════════════════════════════════
    -- FIX #2: Recalculate avg_cost after return
    -- Formula: new_avg = (old_qty * old_avg - deducted_cost) / (old_qty - deducted_qty)
    --          If new_qty <= 0, keep old avg_cost (nothing left)
    -- ══════════════════════════════════════════════════════════
    v_old_qty := coalesce(v_stock_available, 0);  -- was before deduction
    v_old_avg := coalesce(v_stock_avg_cost, 0);
    v_new_qty := v_old_qty - v_qty_base;

    if v_new_qty > 0 and v_old_qty > 0 then
      v_new_avg := greatest(0, (v_old_qty * v_old_avg - coalesce(v_deducted_cost, 0)) / v_new_qty);
    else
      v_new_avg := v_old_avg;  -- keep existing if nothing left
    end if;

    if v_has_sm_warehouse then
      update public.stock_management
      set avg_cost = v_new_avg, last_updated = now(), updated_at = now()
      where item_id::text = v_item_id_text and warehouse_id = v_wh;
    else
      update public.stock_management
      set avg_cost = v_new_avg, last_updated = now(), updated_at = now()
      where item_id::text = v_item_id_text;
    end if;

  end loop;

  -- ── Adjust PO total_amount ──
  if coalesce(v_po.total_amount, 0) > 0 and v_return_total > 0 then
    v_new_total := greatest(0, coalesce(v_po.total_amount, 0) - v_return_total);
    update public.purchase_orders
    set total_amount = v_new_total,
        paid_amount = least(coalesce(purchase_orders.paid_amount, 0), v_new_total),
        updated_at = now()
    where id = p_order_id;
  end if;

  -- ── Audit ──
  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
  values (
    'return', 'purchases',
    concat('Created purchase return ', v_return_id::text, ' for PO ', p_order_id::text),
    auth.uid(), coalesce(p_occurred_at, now()),
    jsonb_build_object('purchaseOrderId', p_order_id::text, 'purchaseReturnId', v_return_id::text, 'reason', nullif(trim(coalesce(p_reason, '')), ''))
  );

  return v_return_id;
end;
$$;

revoke all on function public.create_purchase_return(uuid, jsonb, text, timestamptz) from public;
grant execute on function public.create_purchase_return(uuid, jsonb, text, timestamptz) to authenticated;

notify pgrst, 'reload schema';
