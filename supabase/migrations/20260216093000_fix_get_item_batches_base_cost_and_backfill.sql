set app.allow_ledger_ddl = '1';

do $$
begin
  if to_regclass('public.batches') is not null then
    update public.batches b
    set unit_cost = round(b.foreign_unit_cost * b.fx_rate_at_receipt, 6),
        updated_at = now()
    where b.foreign_unit_cost is not null
      and b.fx_rate_at_receipt is not null
      and b.fx_rate_at_receipt > 0
      and nullif(btrim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(btrim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency());
  end if;
end $$;

do $$
begin
  if to_regclass('public.inventory_movements') is not null and to_regclass('public.batches') is not null then
    update public.inventory_movements im
    set unit_cost = round(b.foreign_unit_cost * b.fx_rate_at_receipt, 6),
        total_cost = round(im.quantity * round(b.foreign_unit_cost * b.fx_rate_at_receipt, 6), 6)
    from public.batches b
    where b.id = im.batch_id
      and im.movement_type = 'purchase_in'
      and b.foreign_unit_cost is not null
      and b.fx_rate_at_receipt is not null
      and b.fx_rate_at_receipt > 0
      and nullif(btrim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(btrim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency());
  end if;
end $$;

do $$
begin
  if to_regclass('public.purchase_receipt_items') is not null and to_regclass('public.batches') is not null then
    update public.purchase_receipt_items pri
    set unit_cost = round(b.foreign_unit_cost * b.fx_rate_at_receipt, 6),
        total_cost = round(pri.quantity * round(b.foreign_unit_cost * b.fx_rate_at_receipt, 6), 6)
    from public.batches b
    where b.receipt_item_id = pri.id
      and b.foreign_unit_cost is not null
      and b.fx_rate_at_receipt is not null
      and b.fx_rate_at_receipt > 0
      and nullif(btrim(coalesce(b.foreign_currency,'')), '') is not null
      and upper(btrim(coalesce(b.foreign_currency,''))) <> upper(public.get_base_currency());
  end if;
end $$;

drop function if exists public.get_item_batches(uuid, uuid);

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
begin
  perform public._require_staff('get_item_batches');

  v_wh := coalesce(p_warehouse_id, public._resolve_default_admin_warehouse_id());
  if v_wh is null then
    raise exception 'warehouse_id is required';
  end if;

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
  where b.item_id::uuid = p_item_id
    and b.warehouse_id = v_wh
    and coalesce(b.status,'active') = 'active'
  group by b.id, b.created_at, b.unit_cost, b.foreign_unit_cost, b.foreign_currency, b.fx_rate_at_receipt, b.quantity_received, b.quantity_consumed, b.quantity_transferred, b.qc_status, q.last_result, q.last_at
  having greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0) - coalesce(b.quantity_transferred, 0), 0) > 0
  order by occurred_at desc;
end;
$$;

revoke all on function public.get_item_batches(uuid, uuid) from public;
grant execute on function public.get_item_batches(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
