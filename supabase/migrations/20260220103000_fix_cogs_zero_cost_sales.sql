set app.allow_ledger_ddl = '1';

create or replace function public.deduct_stock_on_delivery_v2(
  p_order_id uuid,
  p_items jsonb,
  p_warehouse_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_in_store boolean := false;
  v_item jsonb;
  v_item_id text;
  v_requested numeric;
  v_needed numeric;
  v_item_batch_text text;
  v_is_food boolean;
  v_avg_cost numeric;
  v_cost_price numeric;
  v_batch record;
  v_alloc numeric;
  v_unit_cost numeric;
  v_total_cost numeric;
  v_movement_id uuid;
  v_qr numeric;
  v_qc numeric;
begin
  perform public._require_staff('deduct_stock_on_delivery_v2');
  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'warehouse_id is required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  if exists (
    select 1
    from public.inventory_movements im
    where im.reference_table = 'orders'
      and im.reference_id = p_order_id::text
      and im.warehouse_id = p_warehouse_id
      and im.movement_type = 'sale_out'
  ) then
    return;
  end if;

  select (coalesce(nullif(o.data->>'orderSource',''), '') = 'in_store')
  into v_is_in_store
  from public.orders o
  where o.id = p_order_id
  for update;
  if not found then
    raise exception 'order not found';
  end if;

  delete from public.order_item_cogs where order_id = p_order_id;

  for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_item_id := coalesce(nullif(v_item->>'itemId',''), nullif(v_item->>'id',''));
    v_requested := coalesce(nullif(v_item->>'quantity','')::numeric, nullif(v_item->>'qty','')::numeric, 0);
    v_item_batch_text := nullif(v_item->>'batchId', '');
    if v_item_id is null or v_item_id = '' or v_requested <= 0 then
      continue;
    end if;

    select (coalesce(mi.category,'') = 'food'), coalesce(mi.cost_price, 0)
    into v_is_food, v_cost_price
    from public.menu_items mi
    where mi.id::text = v_item_id::text;

    select coalesce(sm.avg_cost, 0)
    into v_avg_cost
    from public.stock_management sm
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = p_warehouse_id;

    v_needed := v_requested;

    if not coalesce(v_is_in_store, false) then
      for v_batch in
        select
          r.id as reservation_id,
          r.quantity as reserved_qty,
          b.id as batch_id,
          b.expiry_date,
          b.unit_cost,
          greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) as remaining_qty
        from public.order_item_reservations r
        join public.batches b on b.id = r.batch_id
        where r.order_id = p_order_id
          and r.item_id::text = v_item_id::text
          and r.warehouse_id = p_warehouse_id
          and (v_item_batch_text is null or r.batch_id <> v_item_batch_text::uuid)
          and coalesce(b.status,'active') = 'active'
          and coalesce(b.qc_status,'') = 'released'
          and not exists (
            select 1 from public.batch_recalls br
            where br.batch_id = b.id and br.status = 'active'
          )
          and (
            not coalesce(v_is_food, false)
            or (b.expiry_date is not null and b.expiry_date >= current_date)
          )
        order by b.expiry_date asc nulls last, r.created_at asc, r.batch_id asc
        for update
      loop
        exit when v_needed <= 0;
        v_alloc := least(v_needed, coalesce(v_batch.reserved_qty, 0));
        if v_alloc <= 0 then
          continue;
        end if;

        update public.batches
        set quantity_consumed = quantity_consumed + v_alloc
        where id = v_batch.batch_id
        returning quantity_received, quantity_consumed into v_qr, v_qc;
        if coalesce(v_qc,0) > coalesce(v_qr,0) then
          raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
        end if;

        v_unit_cost := coalesce(nullif(v_batch.unit_cost, 0), nullif(v_avg_cost, 0), nullif(v_cost_price, 0), 0);
        if v_unit_cost <= 0 then
          raise exception 'MISSING_COGS_COST_FOR_ITEM_%', v_item_id;
        end if;
        v_total_cost := v_alloc * v_unit_cost;
        insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
        values (p_order_id, v_item_id::text, v_alloc, v_unit_cost, v_total_cost, now());

        insert into public.inventory_movements(
          item_id, movement_type, quantity, unit_cost, total_cost,
          reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
        )
        values (
          v_item_id::text, 'sale_out', v_alloc, v_unit_cost, v_total_cost,
          'orders', p_order_id::text, now(), auth.uid(),
          jsonb_build_object('orderId', p_order_id, 'warehouseId', p_warehouse_id, 'batchId', v_batch.batch_id),
          v_batch.batch_id,
          p_warehouse_id
        )
        returning id into v_movement_id;

        perform public.post_inventory_movement(v_movement_id);

        update public.order_item_reservations
        set quantity = quantity - v_alloc,
            updated_at = now()
        where id = v_batch.reservation_id;

        delete from public.order_item_reservations
        where id = v_batch.reservation_id
          and quantity <= 0;

        v_needed := v_needed - v_alloc;
      end loop;

      if v_needed > 0 then
        raise exception 'INSUFFICIENT_RESERVED_BATCH_STOCK_FOR_ITEM_%', v_item_id;
      end if;
    else
      if v_item_batch_text is not null then
        select
          b.id as batch_id,
          b.expiry_date,
          b.unit_cost,
          greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) as remaining_qty
        into v_batch
        from public.batches b
        where b.id = v_item_batch_text::uuid
          and b.item_id::text = v_item_id::text
          and b.warehouse_id = p_warehouse_id
          and coalesce(b.status,'active') = 'active'
          and coalesce(b.qc_status,'') = 'released'
          and not exists (
            select 1 from public.batch_recalls br
            where br.batch_id = b.id and br.status = 'active'
          )
        for update;
        if not found then
          raise exception 'Batch % not found for item % in warehouse %', v_item_batch_text, v_item_id, p_warehouse_id;
        end if;
        if coalesce(v_is_food, false) and (v_batch.expiry_date is null or v_batch.expiry_date < current_date) then
          raise exception 'NO_VALID_BATCH_AVAILABLE';
        end if;
        v_alloc := least(v_needed, coalesce(v_batch.remaining_qty, 0));
        if v_alloc > 0 then
          update public.batches
          set quantity_consumed = quantity_consumed + v_alloc
          where id = v_batch.batch_id
          returning quantity_received, quantity_consumed into v_qr, v_qc;
          if coalesce(v_qc,0) > coalesce(v_qr,0) then
            raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
          end if;

          v_unit_cost := coalesce(nullif(v_batch.unit_cost, 0), nullif(v_avg_cost, 0), nullif(v_cost_price, 0), 0);
          if v_unit_cost <= 0 then
            raise exception 'MISSING_COGS_COST_FOR_ITEM_%', v_item_id;
          end if;
          v_total_cost := v_alloc * v_unit_cost;
          insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
          values (p_order_id, v_item_id::text, v_alloc, v_unit_cost, v_total_cost, now());

          insert into public.inventory_movements(
            item_id, movement_type, quantity, unit_cost, total_cost,
            reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
          )
          values (
            v_item_id::text, 'sale_out', v_alloc, v_unit_cost, v_total_cost,
            'orders', p_order_id::text, now(), auth.uid(),
            jsonb_build_object('orderId', p_order_id, 'warehouseId', p_warehouse_id, 'batchId', v_batch.batch_id),
            v_batch.batch_id,
            p_warehouse_id
          )
          returning id into v_movement_id;

          perform public.post_inventory_movement(v_movement_id);
          v_needed := v_needed - v_alloc;
        end if;
      end if;

      for v_batch in
        select
          b.id as batch_id,
          b.expiry_date,
          b.unit_cost,
          greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) as remaining_qty
        from public.batches b
        where b.item_id::text = v_item_id::text
          and b.warehouse_id = p_warehouse_id
          and coalesce(b.status,'active') = 'active'
          and coalesce(b.qc_status,'') = 'released'
          and not exists (
            select 1 from public.batch_recalls br
            where br.batch_id = b.id and br.status = 'active'
          )
          and greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) > 0
          and (v_item_batch_text is null or b.id <> v_item_batch_text::uuid)
          and (
            not coalesce(v_is_food, false)
            or (b.expiry_date is not null and b.expiry_date >= current_date)
          )
        order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
        for update
      loop
        exit when v_needed <= 0;
        v_alloc := least(v_needed, coalesce(v_batch.remaining_qty, 0));
        if v_alloc <= 0 then
          continue;
        end if;

        update public.batches
        set quantity_consumed = quantity_consumed + v_alloc
        where id = v_batch.batch_id
        returning quantity_received, quantity_consumed into v_qr, v_qc;
        if coalesce(v_qc,0) > coalesce(v_qr,0) then
          raise exception 'Over-consumption detected for batch %', v_batch.batch_id;
        end if;

        v_unit_cost := coalesce(nullif(v_batch.unit_cost, 0), nullif(v_avg_cost, 0), nullif(v_cost_price, 0), 0);
        if v_unit_cost <= 0 then
          raise exception 'MISSING_COGS_COST_FOR_ITEM_%', v_item_id;
        end if;
        v_total_cost := v_alloc * v_unit_cost;
        insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
        values (p_order_id, v_item_id::text, v_alloc, v_unit_cost, v_total_cost, now());

        insert into public.inventory_movements(
          item_id, movement_type, quantity, unit_cost, total_cost,
          reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
        )
        values (
          v_item_id::text, 'sale_out', v_alloc, v_unit_cost, v_total_cost,
          'orders', p_order_id::text, now(), auth.uid(),
          jsonb_build_object('orderId', p_order_id, 'warehouseId', p_warehouse_id, 'batchId', v_batch.batch_id),
          v_batch.batch_id,
          p_warehouse_id
        )
        returning id into v_movement_id;

        perform public.post_inventory_movement(v_movement_id);
        v_needed := v_needed - v_alloc;
      end loop;

      if v_needed > 0 then
        raise exception 'INSUFFICIENT_BATCH_STOCK_FOR_ITEM_%', v_item_id;
      end if;
    end if;

    update public.stock_management sm
    set reserved_quantity = coalesce((
          select sum(r.quantity)
          from public.order_item_reservations r
          where r.item_id = v_item_id::text
            and r.warehouse_id = p_warehouse_id
        ), 0),
        available_quantity = coalesce((
          select sum(
            greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
          )
          from public.batches b
          where b.item_id::text = v_item_id::text
            and b.warehouse_id = p_warehouse_id
            and coalesce(b.status,'active') = 'active'
            and coalesce(b.qc_status,'') = 'released'
            and not exists (
              select 1 from public.batch_recalls br
              where br.batch_id = b.id and br.status = 'active'
            )
            and (
              not coalesce(v_is_food, false)
              or (b.expiry_date is not null and b.expiry_date >= current_date)
            )
        ), 0),
        last_updated = now(),
        updated_at = now()
    where sm.item_id::text = v_item_id::text
      and sm.warehouse_id = p_warehouse_id;
  end loop;
end;
$$;

revoke all on function public.deduct_stock_on_delivery_v2(uuid, jsonb, uuid) from public;
revoke execute on function public.deduct_stock_on_delivery_v2(uuid, jsonb, uuid) from anon;
grant execute on function public.deduct_stock_on_delivery_v2(uuid, jsonb, uuid) to authenticated;

do $$
declare
  v_inventory uuid;
  v_cogs uuid;
  v_entry_id uuid;
  r record;
  v_delta numeric;
begin
  if to_regclass('public.inventory_movements') is null
     or to_regclass('public.batches') is null
     or to_regclass('public.journal_entries') is null
     or to_regclass('public.journal_lines') is null
  then
    return;
  end if;

  v_inventory := public.get_account_id_by_code('1410');
  v_cogs := public.get_account_id_by_code('5010');

  for r in
    with candidates as (
      select
        (im.reference_id)::uuid as order_id,
        sum(im.total_cost) as posted_cogs,
        sum(im.quantity * nullif(b.unit_cost, 0)) as expected_cogs
      from public.inventory_movements im
      join public.batches b on b.id = im.batch_id
      where im.reference_table = 'orders'
        and im.movement_type = 'sale_out'
        and im.batch_id is not null
        and im.occurred_at >= now() - interval '30 days'
        and im.total_cost = 0
        and nullif(b.unit_cost, 0) is not null
      group by (im.reference_id)::uuid
    )
    select
      c.order_id,
      greatest(coalesce(c.expected_cogs, 0) - coalesce(c.posted_cogs, 0), 0) as delta
    from candidates c
    where greatest(coalesce(c.expected_cogs, 0) - coalesce(c.posted_cogs, 0), 0) > 0.000001
  loop
    v_delta := r.delta;

    v_entry_id := null;
    begin
      insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
      values (
        now(),
        concat('COGS correction for order ', r.order_id::text),
        'orders',
        r.order_id::text,
        'cogs_adjustment',
        auth.uid(),
        'posted'
      )
      on conflict (source_table, source_id, source_event) do nothing
      returning id into v_entry_id;
    exception when undefined_column then
      insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
      values (
        now(),
        concat('COGS correction for order ', r.order_id::text),
        'orders',
        r.order_id::text,
        'cogs_adjustment',
        auth.uid()
      )
      on conflict (source_table, source_id, source_event) do nothing
      returning id into v_entry_id;
    end;

    if v_entry_id is not null and v_inventory is not null and v_cogs is not null then
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
      values
        (v_entry_id, v_cogs, public._money_round(v_delta), 0, 'COGS correction'),
        (v_entry_id, v_inventory, 0, public._money_round(v_delta), 'Inventory correction');

      begin
        perform public.check_journal_entry_balance(v_entry_id);
      exception when others then
        null;
      end;
    end if;

    delete from public.order_item_cogs where order_id = r.order_id;

    insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
    select
      r.order_id,
      im.item_id::text,
      sum(im.quantity) as quantity,
      public._money_round(sum(coalesce(nullif(im.total_cost, 0), im.quantity * nullif(b.unit_cost, 0))) / nullif(sum(im.quantity), 0)) as unit_cost,
      public._money_round(sum(coalesce(nullif(im.total_cost, 0), im.quantity * nullif(b.unit_cost, 0)))) as total_cost,
      now()
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    where im.reference_table = 'orders'
      and im.movement_type = 'sale_out'
      and (im.reference_id)::uuid = r.order_id
      and im.batch_id is not null
    group by im.item_id::text;
  end loop;
end $$;

notify pgrst, 'reload schema';
