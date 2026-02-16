-- Fix: Batches Not Showing & Backfill Missing Batches
-- 1. Updates get_item_batches to use text comparison for item_id (safer)
-- 2. Updates get_item_batches to return an "Unbatched" row if stock > batch_sum
-- 3. Backfills missing batches for items that have stock but no batches

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

  -- 1. Get actual stock levels
  select coalesce(available_quantity, 0), coalesce(reserved_quantity, 0), coalesce(avg_cost, 0)
  into v_stock_avail, v_stock_reserved, v_stock_avg
  from public.stock_management
  where item_id::text = p_item_id::text
    and warehouse_id = v_wh;

  -- 2. Calculate total batch remaining
  select coalesce(sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0)), 0)
  into v_total_batch_remaining
  from public.batches b
  where b.item_id = p_item_id::text
    and b.warehouse_id = v_wh
    and coalesce(b.status, 'active') = 'active';

  -- 3. Return Batches
  return query
  select
    b.id as batch_id,
    coalesce(b.created_at, max(im.occurred_at)) as occurred_at,
    coalesce(
      case
        when b.foreign_unit_cost is not null and b.fx_rate_at_receipt is not null and b.fx_rate_at_receipt > 0
          then round(b.foreign_unit_cost * b.fx_rate_at_receipt, 6)
        else null
      end,
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
  where b.item_id = p_item_id::text -- Use text comparison safety
    and b.warehouse_id = v_wh
    and coalesce(b.status,'active') = 'active'
  group by b.id, b.created_at, b.unit_cost, b.foreign_unit_cost, b.foreign_currency, b.fx_rate_at_receipt, b.quantity_received, b.quantity_consumed, b.quantity_transferred, b.qc_status, q.last_result, q.last_at
  having greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) > 0
  order by occurred_at desc;

  -- 4. Append Unbatched Row if needed
  -- v_stock_avail includes QC hold? Usually yes. batches remaining includes QC hold.
  -- Let's assume stock_management.available_quantity + qc_hold_quantity ~= total physical stock
  -- But usually available_quantity is (Physical - Reserved).
  -- Batches "remaining" is Physical. 
  -- So we should compare Total Physical Stock vs Total Batch Remaining.
  
  -- Re-fetch stock to be sure about Physical (Available + Reserved + QC Hold?)
  -- Actually stock_management: 
  -- available_quantity = (Physical - Reserved)  [In some systems]
  -- OR available_quantity = Physical.  [In this system?]
  -- checking schema... usually "available" means sellable. "reserved" is set aside.
  -- "qc_hold" is SEPARATE from available.
  
  -- Let's trust "available + reserved + qc_hold" = Total Physical.
  -- Wait, usually Logic is: Physical = Available + Reserved + QC_Hold.
  -- Let's check logic:
  -- receive_po: 
  --    if pending: qc_hold += qty
  --    else: available += qty
  -- So Total = Available + Reserved + QC Hold.
  
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

-- Backfill Logic
do $$
declare
  v_rec record;
  v_batch_id uuid;
  v_total_stock numeric;
  v_default_wh uuid;
begin
    -- 1. Identify items with stock but ZERO batches (Complete Missing)
    for v_rec in 
        select sm.*, mi.is_food, mi.expiry_required
        from public.stock_management sm
        join public.menu_items mi on mi.id = sm.item_id
        where (coalesce(sm.available_quantity,0) + coalesce(sm.reserved_quantity,0) + coalesce(sm.qc_hold_quantity,0)) > 0
          and not exists (
              select 1 from public.batches b 
              where b.item_id = sm.item_id::text 
                and b.warehouse_id = sm.warehouse_id
                and coalesce(b.status,'active') = 'active'
                and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
          )
    loop
        v_total_stock := coalesce(v_rec.available_quantity,0) + coalesce(v_rec.reserved_quantity,0) + coalesce(v_rec.qc_hold_quantity,0);
        
        insert into public.batches(
          id,
          item_id,
          warehouse_id,
          batch_code,
          production_date,
          expiry_date,
          quantity_received,
          quantity_consumed,
          quantity_transferred,
          unit_cost,
          qc_status,
          status,
          data
        )
        values (
          gen_random_uuid(),
          v_rec.item_id::text,
          v_rec.warehouse_id,
          'LEGACY-BACKFILL',
          null,
          null, -- Legacy items might not have expiry
          v_total_stock,
          0,
          0,
          coalesce(v_rec.avg_cost, 0),
          'released', -- Auto release legacy
          'active',
          jsonb_build_object('source', 'auto_backfill_fix', 'reason', 'missing_batches')
        )
        returning id into v_batch_id;

        -- Update stock management to point to this batch?
        update public.stock_management
        set last_batch_id = v_batch_id
        where item_id = v_rec.item_id and warehouse_id = v_rec.warehouse_id;
        
        raise notice 'Backfilled batch % for item % warehouse % qty %', v_batch_id, v_rec.item_id, v_rec.warehouse_id, v_total_stock;
    end loop;
end $$;
