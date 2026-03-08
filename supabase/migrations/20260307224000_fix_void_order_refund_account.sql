set app.allow_ledger_ddl = '1';

-- Fix cancel_order and void_delivered_order to properly account for shift cash movements
-- and include destination_account_id when returning payments to the shift.
-- Also fixed syntax error in void_delivered_order ar_open_items update.

create or replace function public.cancel_order(
  p_order_id uuid,
  p_reason text default null,
  p_occurred_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_is_cod boolean := false;
  v_wh uuid;
  v_items jsonb := '[]'::jsonb;
  v_mv record;
  v_has_sale_out boolean := false;
  v_reason text;
  v_shift_id uuid;
begin
  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

  select *
  into v_order
  from public.orders o
  where o.id = p_order_id
  for update;

  if not found then
    raise exception 'order not found';
  end if;

  v_is_cod := public._is_cod_delivery_order(coalesce(v_order.data,'{}'::jsonb), v_order.delivery_zone_id);

  if coalesce(nullif(v_order.data->'invoiceSnapshot'->>'issuedAt',''), '') is not null then
    raise exception 'cannot_cancel_settled';
  end if;
  if v_is_cod and coalesce(nullif(v_order.data->>'paidAt',''), '') is not null then
    raise exception 'cannot_cancel_settled';
  end if;
  if exists (select 1 from public.cod_settlement_orders cso where cso.order_id = p_order_id) then
    raise exception 'cannot_cancel_settled';
  end if;

  select exists(
    select 1
    from public.inventory_movements im
    where im.reference_table = 'orders'
      and im.reference_id = p_order_id::text
      and im.movement_type = 'sale_out'
  )
  into v_has_sale_out;

  if v_has_sale_out then
    for v_mv in
      select *
      from public.inventory_movements im
      where im.reference_table = 'orders'
        and im.reference_id = p_order_id::text
        and im.movement_type = 'sale_out'
    loop
      insert into public.inventory_movements(
        item_id, movement_type, quantity, unit_cost, total_cost,
        reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
      )
      values (
        v_mv.item_id,
        'return_in',
        v_mv.quantity,
        coalesce(v_mv.unit_cost, 0),
        coalesce(v_mv.quantity, 0) * coalesce(v_mv.unit_cost, 0),
        'orders',
        p_order_id::text,
        coalesce(p_occurred_at, now()),
        auth.uid(),
        jsonb_build_object('orderId', p_order_id),
        v_mv.batch_id,
        v_mv.warehouse_id
      )
      returning id into v_mv.id;
      perform public.post_inventory_movement(v_mv.id);
    end loop;
  else
    v_wh := coalesce(nullif(v_order.data->>'warehouseId','')::uuid, public._resolve_default_warehouse_id());
    for v_mv in
      select i
      from jsonb_array_elements(coalesce(v_order.data->'items','[]'::jsonb)) as t(i)
    loop
      v_items := v_items || jsonb_build_object(
        'itemId', coalesce(v_mv.i->>'itemId', v_mv.i->>'id'),
        'quantity', coalesce(nullif((v_mv.i->>'quantity')::numeric, null), 0)
      );
    end loop;
    v_items := public._merge_stock_items(v_items);
    if jsonb_array_length(v_items) > 0 then
      perform public.release_reserved_stock_for_order(v_items, p_order_id, v_wh);
    end if;
  end if;

  -- Attempt to get an open shift for the acting user for payment reversals
  v_shift_id := public._resolve_open_shift_for_cash(auth.uid());

  for v_mv in
    select p.id, p.method, p.amount, p.base_amount, p.currency, p.fx_rate, p.destination_account_id
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
      and p.direction = 'in'
  loop
    begin
      -- Reverse in the general ledger
      perform public.reverse_payment_journal(v_mv.id, coalesce(p_reason, 'order_cancel'));
      
      -- If it's cash or a trackable shift method, inject an 'out' payment into the current shift
      if v_mv.method in ('cash','network','kuraimi','bank','bank_transfer','card','online') then
        if v_mv.method = 'cash' and v_shift_id is null then
          raise exception 'cash_refund_requires_open_shift';
        end if;
        insert into public.payments(
          direction, method, amount, currency, base_amount, fx_rate, 
          reference_table, reference_id, occurred_at, created_by, data, shift_id, destination_account_id
        )
        values (
          'out', v_mv.method, coalesce(v_mv.amount, 0), coalesce(v_mv.currency, 'YER'), 
          v_mv.base_amount, v_mv.fx_rate, 
          'orders', p_order_id::text, coalesce(p_occurred_at, now()), auth.uid(), 
          jsonb_build_object('orderId', p_order_id::text, 'event', 'voided_payment'),
          v_shift_id, v_mv.destination_account_id
        );
      end if;
    exception when others then
      -- Re-raise immediately if shift is missing, otherwise swallow
      if SQLERRM = 'cash_refund_requires_open_shift' then
        raise exception '%', SQLERRM;
      end if;
    end;
  end loop;

  v_reason := nullif(trim(coalesce(p_reason,'')),'');
  update public.orders
  set status = 'cancelled',
      data = jsonb_set(coalesce(v_order.data,'{}'::jsonb), '{cancelReason}', to_jsonb(coalesce(v_reason,'')), true),
      updated_at = now()
  where id = p_order_id;
end;
$$;

create or replace function public.void_delivered_order(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_delivered_entry_id uuid;
  v_void_entry_id uuid;
  v_line record;
  v_ar_id uuid;
  v_ar_amount numeric := 0;
  v_sale record;
  v_ret_batch_id uuid;
  v_source_batch record;
  v_movement_id uuid;
  v_wh uuid;
  v_data jsonb;
  v_shift_id uuid;
begin
  perform public._require_staff('void_delivered_order');
  if not (auth.role() = 'service_role' or public.has_admin_permission('accounting.void')) then
    raise exception 'not authorized';
  end if;
  if p_order_id is null then
    raise exception 'p_order_id is required';
  end if;

  select * into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'order not found';
  end if;
  if coalesce(v_order.status,'') <> 'delivered' then
    raise exception 'only delivered orders can be voided';
  end if;

  if coalesce(v_order.data->>'voidedAt','') <> '' then
    raise exception 'order already voided';
  end if;

  select je.id
  into v_delivered_entry_id
  from public.journal_entries je
  where je.source_table = 'orders'
    and je.source_id = p_order_id::text
    and je.source_event = 'delivered'
  limit 1;
  if not found then
    raise exception 'delivered journal entry not found';
  end if;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (
    now(),
    concat('Void delivered order ', p_order_id::text),
    'orders',
    p_order_id::text,
    'voided',
    auth.uid(),
    'posted'
  )
  on conflict (source_table, source_id, source_event)
  do update set entry_date = excluded.entry_date, memo = excluded.memo
  returning id into v_void_entry_id;

  delete from public.journal_lines jl where jl.journal_entry_id = v_void_entry_id;

  for v_line in
    select account_id, debit, credit, line_memo, cost_center_id, party_id, currency_code, fx_rate, foreign_amount
    from public.journal_lines
    where journal_entry_id = v_delivered_entry_id
  loop
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo, cost_center_id, party_id, currency_code, fx_rate, foreign_amount)
    values (
      v_void_entry_id,
      v_line.account_id,
      coalesce(v_line.credit,0),
      coalesce(v_line.debit,0),
      coalesce(v_line.line_memo,''),
      v_line.cost_center_id, v_line.party_id, v_line.currency_code, v_line.fx_rate, v_line.foreign_amount
    );
  end loop;

  v_ar_id := public.get_account_id_by_code('1200');
  if v_ar_id is not null then
    select coalesce(sum(jl.debit), 0) - coalesce(sum(jl.credit), 0)
    into v_ar_amount
    from public.journal_lines jl
    where jl.journal_entry_id = v_delivered_entry_id
      and jl.account_id = v_ar_id;
    v_ar_amount := greatest(0, coalesce(v_ar_amount, 0));
  end if;

  for v_sale in
    select im.id, im.item_id, im.quantity, im.unit_cost, im.batch_id, im.warehouse_id, im.occurred_at
    from public.inventory_movements im
    where im.reference_table = 'orders'
      and im.reference_id = p_order_id::text
      and im.movement_type = 'sale_out'
    order by im.occurred_at asc, im.id asc
  loop
    select b.expiry_date, b.production_date, b.unit_cost
    into v_source_batch
    from public.batches b
    where b.id = v_sale.batch_id;

    v_wh := v_sale.warehouse_id;
    if v_wh is null then
      v_wh := coalesce(v_order.warehouse_id, public._resolve_default_admin_warehouse_id());
    end if;
    if v_wh is null then
      raise exception 'warehouse_id is required';
    end if;

    v_ret_batch_id := gen_random_uuid();
    insert into public.batches(
      id,
      item_id,
      receipt_item_id,
      receipt_id,
      warehouse_id,
      batch_code,
      production_date,
      expiry_date,
      quantity_received,
      quantity_consumed,
      unit_cost,
      qc_status,
      data
    )
    values (
      v_ret_batch_id,
      v_sale.item_id::text,
      null,
      null,
      v_wh,
      null,
      v_source_batch.production_date,
      v_source_batch.expiry_date,
      v_sale.quantity,
      0,
      coalesce(v_sale.unit_cost, v_source_batch.unit_cost, 0),
      'released',
      jsonb_build_object(
        'source', 'orders',
        'event', 'voided',
        'orderId', p_order_id::text,
        'sourceBatchId', v_sale.batch_id::text,
        'sourceMovementId', v_sale.id::text
      )
    );

    insert into public.inventory_movements(
      item_id, movement_type, quantity, unit_cost, total_cost,
      reference_table, reference_id, occurred_at, created_by, data, batch_id, warehouse_id
    )
    values (
      v_sale.item_id::text,
      'return_in',
      v_sale.quantity,
      coalesce(v_sale.unit_cost, v_source_batch.unit_cost, 0),
      v_sale.quantity * coalesce(v_sale.unit_cost, v_source_batch.unit_cost, 0),
      'orders',
      p_order_id::text,
      now(),
      auth.uid(),
      jsonb_build_object(
        'orderId', p_order_id::text,
        'warehouseId', v_wh::text,
        'event', 'voided',
        'sourceBatchId', v_sale.batch_id::text,
        'sourceMovementId', v_sale.id::text
      ),
      v_ret_batch_id,
      v_wh
    )
    returning id into v_movement_id;

    perform public.post_inventory_movement(v_movement_id);
    perform public.recompute_stock_for_item(v_sale.item_id::text, v_wh);
  end loop;

  v_data := coalesce(v_order.data, '{}'::jsonb);
  v_data := jsonb_set(v_data, '{voidedAt}', to_jsonb(now()::text), true);
  if nullif(trim(coalesce(p_reason,'')),'') is not null then
    v_data := jsonb_set(v_data, '{voidReason}', to_jsonb(p_reason), true);
  end if;
  v_data := jsonb_set(v_data, '{voidedBy}', to_jsonb(auth.uid()::text), true);

  update public.orders
  set data = v_data,
      updated_at = now()
  where id = p_order_id;

  if v_ar_amount > 0 then
    update public.ar_open_items target
    set
      original_amount = greatest(0, target.original_amount - v_ar_amount),
      open_balance = greatest(0, least(target.open_balance - v_ar_amount, greatest(0, target.original_amount - v_ar_amount))),
      status = case when greatest(0, least(target.open_balance - v_ar_amount, greatest(0, target.original_amount - v_ar_amount))) = 0 then 'closed' else target.status end,
      closed_at = case when greatest(0, least(target.open_balance - v_ar_amount, greatest(0, target.original_amount - v_ar_amount))) = 0 then now() else target.closed_at end
    where target.invoice_id = p_order_id
      and target.status = 'open';
  end if;

  -- Attempt to get an open shift for the acting user for payment reversals
  v_shift_id := public._resolve_open_shift_for_cash(auth.uid());

  -- Reverse any linked payments (similar to cancel_order)
  for v_sale in
    select p.id, p.method, p.amount, p.base_amount, p.currency, p.fx_rate, p.destination_account_id
    from public.payments p
    where p.reference_table = 'orders'
      and p.reference_id = p_order_id::text
      and p.direction = 'in'
  loop
    begin
      -- Reverse in the general ledger
      perform public.reverse_payment_journal(v_sale.id, coalesce(p_reason, 'order_voided'));
      
      -- If it's cash or a trackable shift method, inject an 'out' payment into the current shift
      if v_sale.method in ('cash','network','kuraimi','bank','bank_transfer','card','online') then
        if v_sale.method = 'cash' and v_shift_id is null then
          raise exception 'cash_refund_requires_open_shift';
        end if;
        insert into public.payments(
          direction, method, amount, currency, base_amount, fx_rate, 
          reference_table, reference_id, occurred_at, created_by, data, shift_id, destination_account_id
        )
        values (
          'out', v_sale.method, coalesce(v_sale.amount, 0), coalesce(v_sale.currency, 'YER'), 
          v_sale.base_amount, v_sale.fx_rate, 
          'orders', p_order_id::text, now(), auth.uid(), 
          jsonb_build_object('orderId', p_order_id::text, 'event', 'voided_payment'),
          v_shift_id, v_sale.destination_account_id
        );
      end if;
    exception when others then
      if SQLERRM = 'cash_refund_requires_open_shift' then
        raise exception '%', SQLERRM;
      end if;
    end;
  end loop;

end;
$$;

revoke all on function public.cancel_order(uuid, text, timestamptz) from public;
grant execute on function public.cancel_order(uuid, text, timestamptz) to authenticated;

revoke all on function public.void_delivered_order(uuid, text) from public;
grant execute on function public.void_delivered_order(uuid, text) to authenticated;

notify pgrst, 'reload schema';
