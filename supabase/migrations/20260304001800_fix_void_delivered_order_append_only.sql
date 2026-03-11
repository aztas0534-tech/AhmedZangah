-- =============================================================================
-- إصلاح: void_delivered_order — التوافق مع نظام append-only ledger
-- السبب: النسخة القديمة تحاول DELETE من journal_lines مما يتعارض مع
--         trigger trg_journal_lines_block_system_mutation
-- الحل:  استبدال DELETE بنمط idempotent (فحص وجود القيود قبل الإنشاء)
-- =============================================================================

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
  v_void_lines_count int := 0;
  v_ar_id uuid;
  v_ar_amount numeric := 0;
  v_sale record;
  v_ret_batch_id uuid;
  v_source_batch record;
  v_movement_id uuid;
  v_wh uuid;
  v_data jsonb;
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

  -- ── 1) البحث عن قيد التسليم الأصلي ──
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

  -- ── 2) إنشاء أو إعادة استخدام قيد العكس (idempotent) ──
  select je.id
  into v_void_entry_id
  from public.journal_entries je
  where je.source_table = 'order_voids'
    and je.source_id = p_order_id::text
    and je.source_event = 'voided'
  limit 1;

  if v_void_entry_id is null then
    insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
    values (
      now(),
      concat('Void delivered order ', p_order_id::text),
      'order_voids',
      p_order_id::text,
      'voided',
      auth.uid(),
      'posted'
    )
    returning id into v_void_entry_id;
  end if;

  -- ── 3) إنشاء سطور العكس فقط إذا لم تكن موجودة (append-only safe) ──
  select count(1)
  into v_void_lines_count
  from public.journal_lines jl
  where jl.journal_entry_id = v_void_entry_id;

  if coalesce(v_void_lines_count, 0) = 0 then
    for v_line in
      select account_id, debit, credit, line_memo
      from public.journal_lines
      where journal_entry_id = v_delivered_entry_id
    loop
      insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
      values (
        v_void_entry_id,
        v_line.account_id,
        coalesce(v_line.credit,0),   -- عكس: المدين يصبح دائن والعكس
        coalesce(v_line.debit,0),
        coalesce(v_line.line_memo,'')
      );
    end loop;
  end if;

  -- ── 4) حساب مبلغ الذمم المدينة للعكس ──
  v_ar_id := public.get_account_id_by_code('1200');
  if v_ar_id is not null then
    select coalesce(sum(jl.debit), 0) - coalesce(sum(jl.credit), 0)
    into v_ar_amount
    from public.journal_lines jl
    where jl.journal_entry_id = v_delivered_entry_id
      and jl.account_id = v_ar_id;
    v_ar_amount := greatest(0, coalesce(v_ar_amount, 0));
  end if;

  -- ── 5) عكس حركات المخزون (إرجاع الدُفعات) — idempotent ──
  if not exists (
    select 1
    from public.inventory_movements im
    where im.reference_table = 'orders'
      and im.reference_id = p_order_id::text
      and im.movement_type = 'return_in'
      and coalesce(im.data->>'event','') = 'voided'
  ) then
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
        id, item_id, receipt_item_id, receipt_id, warehouse_id,
        batch_code, production_date, expiry_date,
        quantity_received, quantity_consumed, unit_cost, qc_status, data
      )
      values (
        v_ret_batch_id,
        v_sale.item_id::text,
        null, null, v_wh, null,
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
  end if;

  -- ── 6) تحديث بيانات الطلب ──
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

  -- ── 7) تسوية الذمم المدينة ──
  perform public._apply_ar_open_item_credit(p_order_id, v_ar_amount);
end;
$$;

-- صلاحيات
revoke all on function public.void_delivered_order(uuid, text) from public;
revoke execute on function public.void_delivered_order(uuid, text) from anon;
grant execute on function public.void_delivered_order(uuid, text) to authenticated;

-- إعادة تحميل Schema
notify pgrst, 'reload schema';
