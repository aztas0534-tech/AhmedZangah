-- Update get_item_batches to return foreign currency data for frontend display
-- Includes DROP FUNCTION due to return type change

drop function if exists public.get_item_batches(uuid, uuid);

create or replace function public.get_item_batches(
  p_item_id uuid,
  p_warehouse_id uuid default null
)
returns table (
  batch_id uuid,
  occurred_at timestamptz,
  unit_cost numeric,
  received_quantity numeric,
  consumed_quantity numeric,
  remaining_quantity numeric,
  qc_status text,
  last_qc_result text,
  last_qc_at timestamptz,
  unit_cost_currency text,
  unit_cost_original numeric,
  fx_rate_at_receipt numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select
    b.id as batch_id,
    max(im.occurred_at) as occurred_at,
    max(im.unit_cost) as unit_cost,
    sum(case when im.movement_type in ('purchase_in', 'opening_balance', 'transfer_in', 'production_in') then im.quantity else 0 end) as received_quantity,
    sum(case when im.movement_type in ('sale_out', 'transfer_out', 'wastage', 'production_out') then im.quantity else 0 end) as consumed_quantity,
    (
      sum(case when im.movement_type in ('purchase_in', 'opening_balance', 'transfer_in', 'production_in') then im.quantity else 0 end) -
      sum(case when im.movement_type in ('sale_out', 'transfer_out', 'wastage', 'production_out') then im.quantity else 0 end)
    ) as remaining_quantity,
    b.qc_status,
    coalesce(q.last_result, 'pending') as last_qc_result,
    q.last_at,
    max(b.foreign_currency) as unit_cost_currency,
    max(b.foreign_unit_cost) as unit_cost_original,
    max(b.fx_rate_at_receipt) as fx_rate_at_receipt
  from public.inventory_movements im
  join public.batches b on b.id = im.batch_id
  left join lateral (
    select
      result as last_result,
      created_at as last_at
    from public.quality_checks
    where batch_id = b.id
    order by created_at desc
    limit 1
  ) q on true
  where im.item_id = p_item_id
    and (p_warehouse_id is null or im.warehouse_id = p_warehouse_id)
  group by b.id, b.qc_status, q.last_result, q.last_at
  having (
    sum(case when im.movement_type in ('purchase_in', 'opening_balance', 'transfer_in', 'production_in') then im.quantity else 0 end) -
    sum(case when im.movement_type in ('sale_out', 'transfer_out', 'wastage', 'production_out') then im.quantity else 0 end)
  ) > 0.0001
  order by max(im.occurred_at) asc;
end;
$$;

notify pgrst, 'reload schema';
