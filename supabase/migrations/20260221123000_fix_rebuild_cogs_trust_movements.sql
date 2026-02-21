set app.allow_ledger_ddl = '1';

create or replace function public.rebuild_order_item_cogs_from_movements(
  p_start_date timestamptz default null,
  p_end_date timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamptz := p_start_date;
  v_end timestamptz := p_end_date;
begin
  if to_regclass('public.orders') is null
     or to_regclass('public.inventory_movements') is null
     or to_regclass('public.order_item_cogs') is null then
    return;
  end if;

  with target_orders as (
    select
      o.id,
      o.data,
      o.created_at,
      coalesce(
        o.warehouse_id,
        case
          when nullif(o.data->>'warehouseId','') is not null
            and (o.data->>'warehouseId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (o.data->>'warehouseId')::uuid
          else null
        end
      ) as warehouse_id
    from public.orders o
    where o.status = 'delivered'
      and (v_start is null or o.created_at >= v_start)
      and (v_end is null or o.created_at <= v_end)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  ),
  expanded_items as (
    select t.id as order_id, t.warehouse_id, item as item
    from target_orders t
    cross join lateral jsonb_array_elements(
      case
        when jsonb_typeof(t.data->'invoiceSnapshot'->'items') = 'array'
             and jsonb_array_length(t.data->'invoiceSnapshot'->'items') > 0 then t.data->'invoiceSnapshot'->'items'
        when jsonb_typeof(t.data->'items') = 'array' then t.data->'items'
        else '[]'::jsonb
      end
    ) as item
  ),
  normalized_items as (
    select
      order_id,
      warehouse_id,
      coalesce(nullif(item->>'itemId',''), nullif(item->>'id',''), nullif(item->>'menuItemId','')) as item_id_text,
      lower(coalesce(nullif(item->>'unitType',''), nullif(item->>'unit',''), 'piece')) as unit_type,
      coalesce(nullif(item->>'quantity','')::numeric, 0) as quantity,
      coalesce(nullif(item->>'weight','')::numeric, 0) as weight,
      coalesce(
        nullif(item->>'uomQtyInBase','')::numeric,
        nullif(item->>'uom_qty_in_base','')::numeric,
        1
      ) as uom_qty_in_base
    from expanded_items
  ),
  expected_base as (
    select
      order_id,
      warehouse_id,
      item_id_text,
      case
        when unit_type in ('kg','gram') then greatest(weight, 0)
        else greatest(quantity, 0) * greatest(coalesce(uom_qty_in_base, 1), 1)
      end as expected_base_qty
    from normalized_items
    where item_id_text is not null and item_id_text <> ''
  ),
  movement_sum as (
    select
      im.reference_id::uuid as order_id,
      im.item_id::text as item_id_text,
      sum(coalesce(im.quantity,0)) as movement_qty,
      sum(coalesce(nullif(im.total_cost,0), im.quantity * im.unit_cost, 0)) as movement_total_cost
    from public.inventory_movements im
    join target_orders o on o.id::text = im.reference_id::text
    where im.reference_table = 'orders'
      and im.movement_type = 'sale_out'
    group by im.reference_id, im.item_id
  ),
  item_keys as (
    select
      eb.order_id,
      eb.warehouse_id,
      eb.item_id_text,
      eb.expected_base_qty
    from expected_base eb
    union
    select
      ms.order_id,
      to2.warehouse_id,
      ms.item_id_text,
      null::numeric as expected_base_qty
    from movement_sum ms
    join target_orders to2 on to2.id = ms.order_id
  ),
  fallback_cost as (
    select
      k.order_id,
      k.item_id_text,
      coalesce(sm.avg_cost, mi.cost_price, 0) as fallback_unit_cost
    from item_keys k
    left join public.stock_management sm
      on sm.item_id::text = k.item_id_text
      and (k.warehouse_id is null or sm.warehouse_id = k.warehouse_id)
    left join public.menu_items mi
      on mi.id::text = k.item_id_text
  ),
  rebuilt as (
    select
      k.order_id,
      k.item_id_text,
      case
        when coalesce(ms.movement_qty, 0) > 0 then ms.movement_qty
        else coalesce(k.expected_base_qty, 0)
      end as quantity,
      case
        when coalesce(ms.movement_qty, 0) > 0 then (ms.movement_total_cost / nullif(ms.movement_qty, 0))
        when coalesce(k.expected_base_qty, 0) > 0 then coalesce(fc.fallback_unit_cost, 0)
        else 0
      end as unit_cost,
      case
        when coalesce(ms.movement_qty, 0) > 0 then ms.movement_total_cost
        when coalesce(k.expected_base_qty, 0) > 0 then (k.expected_base_qty * coalesce(fc.fallback_unit_cost, 0))
        else 0
      end as total_cost
    from item_keys k
    left join movement_sum ms
      on ms.order_id = k.order_id and ms.item_id_text = k.item_id_text
    left join fallback_cost fc
      on fc.order_id = k.order_id and fc.item_id_text = k.item_id_text
    where coalesce(ms.movement_qty, 0) > 0 or coalesce(k.expected_base_qty, 0) > 0
  ),
  deleted as (
    delete from public.order_item_cogs oic
    using target_orders t
    where oic.order_id = t.id
    returning oic.order_id
  )
  insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
  select
    r.order_id,
    r.item_id_text,
    r.quantity,
    r.unit_cost,
    r.total_cost,
    now()
  from rebuilt r
  where r.quantity > 0 and r.total_cost >= 0;
end;
$$;

select public.rebuild_order_item_cogs_from_movements(null, null);

notify pgrst, 'reload schema';
