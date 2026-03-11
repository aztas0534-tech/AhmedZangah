-- ============================================================================
-- FIX: get_item_batches is using OLD version with INNER JOIN on inventory_movements
-- This causes returned batches (which have no inventory_movements) to be excluded.
-- Solution: Re-deploy the correct version that uses LEFT JOIN and reads
-- directly from batches columns.
-- ============================================================================

-- Must DROP first because return type changed (more columns in new version)
drop function if exists public.get_item_batches(uuid, uuid);
drop function if exists public.get_item_batches(uuid);

create or replace function public.get_item_batches(
  p_item_id uuid,
  p_warehouse_id uuid default null
)
returns table (
  batch_id uuid,
  occurred_at timestamptz,
  unit_cost numeric,
  unit_cost_original numeric,
  currency text,
  fx_rate_at_receipt numeric,
  received_quantity numeric,
  consumed_quantity numeric,
  remaining_quantity numeric,
  qc_status text,
  last_qc_result text,
  last_qc_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wh uuid;
  v_stock_avail numeric;
  v_stock_reserved numeric;
  v_stock_avg numeric;
  v_total_batch_remaining numeric;
  v_unbatched_qty numeric;
begin
  perform public._require_staff('get_item_batches');

  v_wh := coalesce(p_warehouse_id, public._resolve_default_admin_warehouse_id());
  if v_wh is null then
    raise exception 'warehouse_id is required';
  end if;

  select coalesce(available_quantity, 0), coalesce(reserved_quantity, 0), coalesce(avg_cost, 0)
  into v_stock_avail, v_stock_reserved, v_stock_avg
  from public.stock_management
  where item_id::text = p_item_id::text
    and warehouse_id = v_wh;

  select coalesce(sum(greatest(coalesce(b2.quantity_received, 0) - coalesce(b2.quantity_consumed, 0) - coalesce(b2.quantity_transferred, 0), 0)), 0)
  into v_total_batch_remaining
  from public.batches b2
  where b2.item_id = p_item_id::text
    and b2.warehouse_id = v_wh
    and coalesce(b2.status, 'active') = 'active';

  -- Use LEFT JOIN so batches without inventory_movements (e.g. from returns) are included
  return query
  select
    b.id as batch_id,
    coalesce(b.created_at, max(im.occurred_at)) as occurred_at,
    coalesce(
      nullif(b.unit_cost, 0),
      max(im.unit_cost),
      0
    ) as unit_cost,
    b.foreign_unit_cost as unit_cost_original,
    b.foreign_currency as currency,
    b.fx_rate_at_receipt as fx_rate_at_receipt,
    coalesce(b.quantity_received, 0) as received_quantity,
    coalesce(b.quantity_consumed, 0) + coalesce(b.quantity_transferred, 0) as consumed_quantity,
    greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) as remaining_quantity,
    coalesce(b.qc_status,'released') as qc_status,
    q.last_result as last_qc_result,
    q.last_at as last_qc_at
  from public.batches b
  left join public.inventory_movements im on im.batch_id = b.id
  left join lateral (
    select qc.result as last_result, qc.checked_at as last_at
    from public.qc_checks qc
    where qc.batch_id = b.id
      and qc.check_type = 'inspection'
    order by qc.checked_at desc
    limit 1
  ) q on true
  where b.item_id = p_item_id::text
    and b.warehouse_id = v_wh
    and coalesce(b.status,'active') = 'active'
  group by b.id, b.created_at, b.unit_cost, b.foreign_unit_cost, b.foreign_currency, b.fx_rate_at_receipt, b.quantity_received, b.quantity_consumed, b.quantity_transferred, b.qc_status, q.last_result, q.last_at
  having greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) > 0
  order by occurred_at desc;

  -- Append Unbatched Row if needed
  declare
    v_total_stock numeric;
    v_qc_hold numeric;
  begin
    select coalesce(qc_hold_quantity, 0) into v_qc_hold from public.stock_management where item_id::text = p_item_id::text and warehouse_id = v_wh;
    v_total_stock := coalesce(v_stock_avail, 0) + coalesce(v_stock_reserved, 0) + coalesce(v_qc_hold, 0);
    v_unbatched_qty := v_total_stock - v_total_batch_remaining;
    if v_unbatched_qty > 0.001 then
        return query select
            '00000000-0000-0000-0000-000000000000'::uuid as batch_id,
            now() as occurred_at,
            v_stock_avg as unit_cost,
            null::numeric as unit_cost_original,
            null::text as currency,
            null::numeric as fx_rate_at_receipt,
            v_unbatched_qty as received_quantity,
            0::numeric as consumed_quantity,
            v_unbatched_qty as remaining_quantity,
            'unbatched'::text as qc_status,
            null::text as last_qc_result,
            null::timestamptz as last_qc_at;
    end if;
  end;
end;
$$;

revoke all on function public.get_item_batches(uuid, uuid) from public;
grant execute on function public.get_item_batches(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
