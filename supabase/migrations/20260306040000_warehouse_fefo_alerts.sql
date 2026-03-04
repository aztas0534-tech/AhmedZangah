-- ═══════════════════════════════════════════════════════════════
-- Cross-warehouse FEFO Smart Alerts for POS
-- Returns alerts when a warehouse is selected for an item:
-- 1) Another warehouse has older batch (FEFO priority)
-- 2) Another warehouse has earlier expiry (sell first)
-- 3) Current warehouse has expired batches
-- 4) Current warehouse has near-expiry batches (30 days)
-- 5) Item out of stock in current warehouse
-- 6) Low stock (qty < requested)
-- 7) Multiple cost layers warning
-- ═══════════════════════════════════════════════════════════════

create or replace function public.get_warehouse_item_alerts(
  p_item_id uuid,
  p_warehouse_id uuid,
  p_requested_qty numeric default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alerts jsonb := '[]'::jsonb;
  v_current_stock numeric := 0;
  v_current_oldest_batch timestamptz;
  v_current_earliest_expiry date;
  v_current_expired_count integer := 0;
  v_current_near_expiry_count integer := 0;
  v_current_distinct_costs integer := 0;
  v_current_remaining numeric := 0;
  v_other record;
  v_warehouse_name text;
  v_other_warehouse_name text;
begin
  -- Get current warehouse name
  select w.name into v_warehouse_name
  from public.warehouses w where w.id = p_warehouse_id;

  -- ── Current warehouse batch analysis ──
  select
    coalesce(sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0),0)),0),
    min(coalesce(b.created_at, now())),
    min(b.expiry_date),
    count(*) filter (where b.expiry_date is not null and b.expiry_date < current_date),
    count(*) filter (where b.expiry_date is not null and b.expiry_date >= current_date and b.expiry_date <= current_date + 30),
    count(distinct round(b.unit_cost, 2))
  into v_current_remaining, v_current_oldest_batch, v_current_earliest_expiry,
       v_current_expired_count, v_current_near_expiry_count, v_current_distinct_costs
  from public.batches b
  where b.item_id = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status,'active') = 'active'
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0),0) > 0;

  -- Also check stock_management
  select coalesce(sm.available_quantity,0)
  into v_current_stock
  from public.stock_management sm
  where sm.item_id::text = p_item_id::text and sm.warehouse_id = p_warehouse_id;

  -- ── Alert 1: Out of stock ──
  if coalesce(v_current_stock,0) <= 0 and coalesce(v_current_remaining,0) <= 0 then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'out_of_stock', 'severity', 'error',
      'message', 'الصنف غير متوفر في هذا المستودع',
      'warehouse', v_warehouse_name
    );
  -- ── Alert 2: Low stock ──
  elsif coalesce(v_current_stock,0) > 0 and coalesce(v_current_stock,0) < p_requested_qty then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'low_stock', 'severity', 'warning',
      'message', 'المخزون أقل من الكمية المطلوبة (' || coalesce(v_current_stock,0)::text || ' متوفر)',
      'available', coalesce(v_current_stock,0)
    );
  end if;

  -- ── Alert 3: Expired batches ──
  if v_current_expired_count > 0 then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'expired', 'severity', 'error',
      'message', 'يوجد ' || v_current_expired_count || ' دفعة منتهية الصلاحية في هذا المستودع!',
      'count', v_current_expired_count
    );
  end if;

  -- ── Alert 4: Near expiry ──
  if v_current_near_expiry_count > 0 then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'near_expiry', 'severity', 'warning',
      'message', v_current_near_expiry_count || ' دفعة تنتهي خلال 30 يوم (أقرب: ' || coalesce(v_current_earliest_expiry::text, '—') || ')',
      'earliest_expiry', v_current_earliest_expiry,
      'count', v_current_near_expiry_count
    );
  end if;

  -- ── Alert 5: Multiple cost layers ──
  if v_current_distinct_costs > 1 then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'multi_cost', 'severity', 'info',
      'message', 'يوجد ' || v_current_distinct_costs || ' أسعار تكلفة مختلفة في هذا المستودع',
      'count', v_current_distinct_costs
    );
  end if;

  -- ── Cross-warehouse FEFO analysis ──
  for v_other in
    select
      b.warehouse_id as wh_id,
      w.name as wh_name,
      min(coalesce(b.created_at, now())) as oldest_batch_date,
      min(b.expiry_date) as earliest_expiry,
      sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0),0)) as total_remaining,
      count(*) filter (where b.expiry_date is not null and b.expiry_date < current_date) as expired_count,
      count(*) filter (where b.expiry_date is not null and b.expiry_date >= current_date and b.expiry_date <= current_date + 30) as near_expiry_count
    from public.batches b
    inner join public.warehouses w on w.id = b.warehouse_id
    where b.item_id = p_item_id::text
      and b.warehouse_id <> p_warehouse_id
      and coalesce(b.status,'active') = 'active'
      and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0),0) > 0
      and w.is_active = true
    group by b.warehouse_id, w.name
    having sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0),0)) > 0
  loop
    -- ── Alert 6: Another warehouse has OLDER batch (should sell first) ──
    if v_other.oldest_batch_date is not null
       and v_current_oldest_batch is not null
       and v_other.oldest_batch_date < v_current_oldest_batch then
      v_alerts := v_alerts || jsonb_build_object(
        'type', 'fefo_older_batch', 'severity', 'warning',
        'message', '⚠️ مستودع "' || v_other.wh_name || '" فيه دفعة أقدم (' ||
          to_char(v_other.oldest_batch_date, 'YYYY-MM-DD') ||
          ') — يُفضل البيع منه أولاً',
        'other_warehouse_id', v_other.wh_id,
        'other_warehouse', v_other.wh_name,
        'other_oldest', v_other.oldest_batch_date,
        'current_oldest', v_current_oldest_batch,
        'other_remaining', v_other.total_remaining
      );
    end if;

    -- ── Alert 7: Another warehouse has EARLIER expiry (FEFO priority) ──
    if v_other.earliest_expiry is not null then
      -- Case A: Current warehouse has no expiring batches but another does
      if v_current_earliest_expiry is null then
        v_alerts := v_alerts || jsonb_build_object(
          'type', 'fefo_expiry_priority', 'severity', 'warning',
          'message', '⚠️ مستودع "' || v_other.wh_name || '" فيه دفعة تنتهي صلاحيتها (' ||
            v_other.earliest_expiry::text || ') — بِعها أولاً',
          'other_warehouse_id', v_other.wh_id,
          'other_warehouse', v_other.wh_name,
          'other_expiry', v_other.earliest_expiry,
          'other_remaining', v_other.total_remaining
        );
      -- Case B: Another warehouse has earlier expiry than current
      elsif v_other.earliest_expiry < v_current_earliest_expiry then
        v_alerts := v_alerts || jsonb_build_object(
          'type', 'fefo_expiry_priority', 'severity', 'warning',
          'message', '⚠️ مستودع "' || v_other.wh_name || '" فيه صلاحية أقرب (' ||
            v_other.earliest_expiry::text || ' مقابل ' || v_current_earliest_expiry::text ||
            ') — يُفضل البيع منه أولاً',
          'other_warehouse_id', v_other.wh_id,
          'other_warehouse', v_other.wh_name,
          'other_expiry', v_other.earliest_expiry,
          'current_expiry', v_current_earliest_expiry,
          'other_remaining', v_other.total_remaining
        );
      end if;
    end if;

    -- ── Alert 8: Another warehouse has expired stock (needs urgent action) ──
    if v_other.expired_count > 0 then
      v_alerts := v_alerts || jsonb_build_object(
        'type', 'other_expired', 'severity', 'error',
        'message', '🔴 مستودع "' || v_other.wh_name || '" فيه ' || v_other.expired_count ||
          ' دفعة منتهية الصلاحية — يجب مراجعتها',
        'other_warehouse_id', v_other.wh_id,
        'other_warehouse', v_other.wh_name,
        'expired_count', v_other.expired_count
      );
    end if;
  end loop;

  -- ── Alert 9: Stock OK (positive confirmation) ──
  if coalesce(v_current_stock,0) >= p_requested_qty and v_current_expired_count = 0 then
    -- Only show if no critical alerts exist
    if not exists (select 1 from jsonb_array_elements(v_alerts) a where a->>'severity' in ('error', 'warning')) then
      v_alerts := v_alerts || jsonb_build_object(
        'type', 'stock_ok', 'severity', 'success',
        'message', '✅ المخزون كافٍ (' || coalesce(v_current_stock,0)::text || ' متوفر)',
        'available', coalesce(v_current_stock,0)
      );
    end if;
  end if;

  return v_alerts;
end;
$$;

revoke all on function public.get_warehouse_item_alerts(uuid, uuid, numeric) from public;
grant execute on function public.get_warehouse_item_alerts(uuid, uuid, numeric) to authenticated;

notify pgrst, 'reload schema';
