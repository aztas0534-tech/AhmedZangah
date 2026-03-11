create or replace function public.get_product_sales_report_v9(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_zone_id uuid default null,
  p_invoice_only boolean default false
)
returns table (
  item_id text,
  item_name jsonb,
  unit_type text,
  quantity_sold numeric,
  total_sales numeric,
  total_cost numeric,
  total_profit numeric,
  current_stock numeric,
  reserved_stock numeric,
  current_cost_price numeric,
  avg_inventory numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;

  return query
  with effective_orders as (
    select
      o.id,
      o.data,
      o.status,
      o.payment_method,
      nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
      case
        when p_invoice_only
          then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
        else coalesce(
          nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
          nullif(o.data->>'paidAt', '')::timestamptz,
          nullif(o.data->>'deliveredAt', '')::timestamptz,
          nullif(o.data->>'closedAt', '')::timestamptz,
          o.created_at
        )
      end as date_by,
      coalesce(
        nullif(btrim(coalesce(o.currency, '')), ''),
        nullif(btrim(coalesce(o.data->>'currency', '')), ''),
        public.get_base_currency()
      ) as currency_code,
      o.fx_rate as fx_rate_raw,
      coalesce(
        o.delivery_zone_id,
        case
          when nullif(o.data->>'deliveryZoneId','') is not null
               and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (o.data->>'deliveryZoneId')::uuid
          else null
        end
      ) as zone_effective,
      coalesce(
        nullif(o.data->>'discountAmount','')::numeric,
        nullif(o.data->>'discountTotal','')::numeric,
        nullif(o.data->>'discount','')::numeric,
        0
      ) as discount_amount,
      coalesce(nullif(o.data->>'subtotal','')::numeric, 0) as subtotal_amount
    from public.orders o
    where (p_zone_id is null or coalesce(
      o.delivery_zone_id,
      case
        when nullif(o.data->>'deliveryZoneId','') is not null
             and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{12}$'
          then (o.data->>'deliveryZoneId')::uuid
        else null
      end
    ) = p_zone_id)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  ),
  sales_orders as (
    select
      eo.*,
      public.order_fx_rate(eo.currency_code, eo.date_by, eo.fx_rate_raw) as fx_rate
    from effective_orders eo
    where (
        eo.paid_at is not null
        or eo.status = 'delivered'
    )
      and eo.date_by >= p_start_date
      and eo.date_by <= p_end_date
  ),
  exploded_items as (
    select
      so.id as order_id,
      so.fx_rate,
      so.discount_amount,
      so.subtotal_amount,
      item
    from sales_orders so,
    lateral jsonb_array_elements(
        case
          when so.data->'invoiceSnapshot'->'items' is not null
               and jsonb_typeof(so.data->'invoiceSnapshot'->'items') = 'array'
            then so.data->'invoiceSnapshot'->'items'
          else
            case
              when jsonb_typeof(so.data->'items') = 'array' then so.data->'items'
              else '[]'::jsonb
            end
        end
      ) as item
  ),
  item_resolved as (
    select
      ei.order_id,
      ei.fx_rate,
      ei.discount_amount,
      ei.subtotal_amount,
      ei.item,
      mi_res.resolved_id as resolved_item_id,
      mi_res.resolved_unit_type as resolved_unit_type
    from exploded_items ei
    left join lateral (
      select mi.id::text as resolved_id, mi.unit_type as resolved_unit_type
      from public.menu_items mi
      where (
        mi.id::text = coalesce(
          nullif(ei.item->>'itemId',''),
          nullif(ei.item->>'id',''),
          nullif(ei.item->>'menuItemId','')
        )
        or (ei.item->'name'->>'ar' is not null and mi.data->'name'->>'ar' = ei.item->'name'->>'ar')
        or (ei.item->'name'->>'en' is not null and mi.data->'name'->>'en' = ei.item->'name'->>'en')
      )
      order by mi.updated_at desc
      limit 1
    ) as mi_res on true
  ),
  normalized_items as (
    select
      ir.order_id,
      coalesce(
        nullif(ir.item->>'itemId', ''),
        nullif(ir.item->>'id', ''),
        nullif(ir.item->>'menuItemId', ''),
        nullif(ir.resolved_item_id, '')
      ) as item_id_text,
      coalesce(ir.item->'name', jsonb_build_object('ar','—')) as name_json,
      coalesce(
        nullif(ir.item->>'unitType', ''),
        nullif(ir.resolved_unit_type, ''),
        'piece'
      ) as unit_type,
      coalesce((ir.item->>'quantity')::numeric, 1) as quantity,
      coalesce(nullif(ir.item->>'weight','')::numeric, 0) as weight,
      coalesce(
        nullif(ir.item->>'uomQtyInBase','')::numeric,
        nullif(ir.item->>'uom_qty_in_base','')::numeric,
        1
      ) as uom_qty_in_base,
      coalesce(
        nullif(ir.item->>'price','')::numeric,
        nullif(ir.item->>'unitPrice','')::numeric,
        0
      ) as price,
      coalesce(nullif(ir.item->>'pricePerUnit','')::numeric, 0) as price_per_unit,
      case
        when ir.item->'selectedAddons' is not null
             and jsonb_typeof(ir.item->'selectedAddons') = 'array'
             and jsonb_array_length(ir.item->'selectedAddons') > 0
        then (
          select coalesce(
            sum(
              coalesce((addon_value->>'price')::numeric, 0)
              * coalesce((addon_value->>'quantity')::numeric, 0)
            ),
          0)
          from jsonb_array_elements(ir.item->'selectedAddons') as addon_value
        )
        else 0
      end as addons_total,
      ir.fx_rate,
      ir.discount_amount,
      ir.subtotal_amount
    from item_resolved ir
  ),
  order_item_gross as (
    select
      ni.order_id,
      ni.item_id_text,
      max(ni.name_json) as any_name,
      max(ni.unit_type) as any_unit,
      sum(
        case
          when ni.unit_type in ('kg', 'gram') and ni.weight > 0
            then greatest(ni.weight * greatest(ni.quantity, 1), 0)
          else greatest(ni.quantity, 0)
        end
      ) as qty_sold,
      sum(
        case
          when ni.unit_type in ('kg', 'gram') and ni.weight > 0
            then greatest(ni.weight * greatest(ni.quantity, 1), 0)
          else greatest(ni.quantity, 0) * greatest(coalesce(ni.uom_qty_in_base, 1), 1)
        end
      ) as qty_base,
      sum(
        (
          (
            case
              when ni.unit_type = 'gram'
                   and ni.price_per_unit > 0
                   and ni.weight > 0 then (ni.price_per_unit / 1000.0) * ni.weight
              when ni.unit_type in ('kg', 'gram')
                   and ni.weight > 0 then ni.price * ni.weight
              else ni.price
            end
            + ni.addons_total
          )
          *
          case
            when ni.unit_type in ('kg', 'gram') and ni.weight > 0
              then greatest(ni.quantity, 1)
            else greatest(ni.quantity, 0) * greatest(coalesce(ni.uom_qty_in_base, 1), 1)
          end
        )
      ) as line_gross,
      max(ni.fx_rate) as fx_rate,
      max(ni.discount_amount) as discount_amount,
      max(ni.subtotal_amount) as subtotal_amount
    from normalized_items ni
    where nullif(ni.item_id_text, '') is not null
    group by ni.order_id, ni.item_id_text
  ),
  order_totals as (
    select
      oig.order_id,
      max(oig.fx_rate) as fx_rate,
      coalesce(sum(oig.line_gross), 0) as items_gross_sum,
      max(oig.discount_amount) as discount_amount,
      max(oig.subtotal_amount) as subtotal_amount
    from order_item_gross oig
    group by oig.order_id
  ),
  order_scaling as (
    select
      ot.order_id,
      ot.fx_rate,
      greatest(coalesce(ot.items_gross_sum, 0), 0) as items_gross_sum,
      greatest(coalesce(ot.subtotal_amount, 0), 0) as subtotal_amount,
      greatest(coalesce(ot.discount_amount, 0), 0) as discount_amount,
      greatest(
        case
          when coalesce(ot.subtotal_amount, 0) > 0 then ot.subtotal_amount
          else coalesce(ot.items_gross_sum, 0)
        end,
        0
      ) as base_amount,
      case
        when coalesce(ot.subtotal_amount, 0) > 0 and coalesce(ot.items_gross_sum, 0) > 0
          then (ot.subtotal_amount / ot.items_gross_sum)
        else 1
      end as scale_to_subtotal
    from order_totals ot
  ),
  order_item_net_by_order as (
    select
      oig.order_id,
      oig.item_id_text,
      max(oig.any_name) as any_name,
      max(oig.any_unit) as any_unit,
      sum(oig.qty_sold) as qty_sold,
      sum(oig.qty_base) as qty_base,
      sum(
        greatest(
          (oig.line_gross * os.scale_to_subtotal)
          - (least(os.discount_amount, os.base_amount) * ((oig.line_gross * os.scale_to_subtotal) / nullif(os.base_amount, 0))),
          0
        ) * coalesce(os.fx_rate, 1)
      ) as net_sales
    from order_item_gross oig
    join order_scaling os on os.order_id = oig.order_id
    group by oig.order_id, oig.item_id_text
  ),
  sales_lines as (
    select
      oin.item_id_text,
      max(oin.any_name) as any_name,
      max(oin.any_unit) as any_unit,
      sum(oin.qty_sold) as qty_sold,
      sum(oin.qty_base) as qty_base,
      sum(oin.net_sales) as net_sales
    from order_item_net_by_order oin
    group by oin.item_id_text
  ),
  returns_base as (
    select
      sr.id as return_id,
      sr.order_id,
      sr.total_refund_amount as return_amount,
      sr.items as items,
      public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      ) as fx_rate,
      coalesce(
        nullif(o.data->>'discountAmount','')::numeric,
        nullif(o.data->>'discountTotal','')::numeric,
        nullif(o.data->>'discount','')::numeric,
        0
      ) as discount_amount,
      coalesce(nullif(o.data->>'subtotal','')::numeric, 0) as subtotal_amount
    from public.sales_returns sr
    join public.orders o on o.id = sr.order_id
    where sr.status = 'approved'
      and sr.created_at >= p_start_date
      and sr.created_at <= p_end_date
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
      and (p_zone_id is null or coalesce(
        o.delivery_zone_id,
        case
          when nullif(o.data->>'deliveryZoneId','') is not null
               and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{12}$'
            then (o.data->>'deliveryZoneId')::uuid
          else null
        end
      ) = p_zone_id)
  ),
  returns_items as (
    select
      rb.return_id,
      rb.order_id,
      coalesce(
        nullif(ri.value->>'itemId',''),
        nullif(ri.value->>'id',''),
        nullif(ri.value->>'menuItemId','')
      ) as item_id_text,
      coalesce((ri.value->>'quantity')::numeric, 0) as qty_returned,
      rb.return_amount
    from returns_base rb,
    lateral jsonb_array_elements(rb.items) as ri(value)
  ),
  normalized_return_items as (
    select
      rb.return_id,
      rb.order_id,
      coalesce(
        nullif(nri.value->>'itemId',''),
        nullif(nri.value->>'id',''),
        nullif(nri.value->>'menuItemId','')
      ) as item_id_text,
      coalesce(
        nullif(nri.value->>'unitType',''),
        'piece'
      ) as unit_type,
      coalesce((nri.value->>'quantity')::numeric, 1) as quantity,
      coalesce(nullif(nri.value->>'weight','')::numeric, 0) as weight,
      coalesce(
        nullif(nri.value->>'uomQtyInBase','')::numeric,
        nullif(nri.value->>'uom_qty_in_base','')::numeric,
        1
      ) as uom_qty_in_base,
      coalesce(
        nullif(nri.value->>'price','')::numeric,
        nullif(nri.value->>'unitPrice','')::numeric,
        0
      ) as price,
      coalesce(nullif(nri.value->>'pricePerUnit','')::numeric, 0) as price_per_unit,
      case
        when nri.value->'selectedAddons' is not null
             and jsonb_typeof(nri.value->'selectedAddons') = 'array'
             and jsonb_array_length(nri.value->'selectedAddons') > 0
        then (
          select coalesce(
            sum(
              coalesce((av->>'price')::numeric, 0)
              * coalesce((av->>'quantity')::numeric, 0)
            ),
          0)
          from jsonb_array_elements(nri.value->'selectedAddons') as av
        )
        else 0
      end as addons_total,
      rb.discount_amount,
      rb.subtotal_amount
    from returns_base rb,
    lateral jsonb_array_elements(
      case
        when rb.items is not null and jsonb_typeof(rb.items) = 'array'
          then rb.items
        else '[]'::jsonb
      end
    ) as nri(value)
  ),
  return_order_item_gross as (
    select
      nri.order_id,
      nri.item_id_text,
      sum(
        case
          when nri.unit_type in ('kg', 'gram') and nri.weight > 0
            then greatest(nri.weight * greatest(nri.quantity, 1), 0)
          else greatest(nri.quantity, 0)
        end
      ) as qty_stock,
      sum(
        (
          (
            case
              when nri.unit_type = 'gram'
                   and nri.price_per_unit > 0
                   and nri.weight > 0 then (nri.price_per_unit / 1000.0) * nri.weight
              when nri.unit_type in ('kg', 'gram')
                   and nri.weight > 0 then nri.price * nri.weight
              else nri.price
            end
            + nri.addons_total
          )
          *
          case
            when nri.unit_type in ('kg', 'gram') and nri.weight > 0
              then greatest(nri.quantity, 1)
            else greatest(nri.quantity, 0) * greatest(coalesce(nri.uom_qty_in_base, 1), 1)
          end
        )
      ) as line_gross
    from normalized_return_items nri
    where nullif(nri.item_id_text,'') is not null
    group by nri.order_id, nri.item_id_text
  ),
  return_order_totals as (
    select
      rb.order_id,
      coalesce(sum(roig.line_gross), 0) as items_gross_sum,
      max(rb.discount_amount) as discount_amount,
      max(rb.subtotal_amount) as subtotal_amount
    from returns_base rb
    left join return_order_item_gross roig on roig.order_id = rb.order_id
    group by rb.order_id
  ),
  return_order_scaling as (
    select
      rot.order_id,
      greatest(coalesce(rot.items_gross_sum, 0), 0) as items_gross_sum,
      greatest(coalesce(rot.subtotal_amount, 0), 0) as subtotal_amount,
      greatest(coalesce(rot.discount_amount, 0), 0) as discount_amount,
      greatest(
        case
          when coalesce(rot.subtotal_amount, 0) > 0 then rot.subtotal_amount
          else coalesce(rot.items_gross_sum, 0)
        end,
        0
      ) as base_amount,
      case
        when coalesce(rot.subtotal_amount, 0) > 0 and coalesce(rot.items_gross_sum, 0) > 0
          then (rot.subtotal_amount / rot.items_gross_sum)
        else 1
      end as scale_to_subtotal
    from return_order_totals rot
  ),
  return_order_item_net as (
    select
      roig.order_id,
      roig.item_id_text,
      roig.qty_stock,
      greatest(
        (roig.line_gross * ros.scale_to_subtotal)
        - (least(ros.discount_amount, ros.base_amount) * ((roig.line_gross * ros.scale_to_subtotal) / nullif(ros.base_amount, 0))),
        0
      ) as net_sales_amount
    from return_order_item_gross roig
    join return_order_scaling ros on ros.order_id = roig.order_id
  ),
  return_item_gross_value as (
    select
      ri.return_id,
      ri.order_id,
      ri.item_id_text,
      ri.qty_returned,
      ri.return_amount,
      case
        when roin.qty_stock > 0
          then (ri.qty_returned * (roin.net_sales_amount / roin.qty_stock))
        else 0
      end as gross_value
    from returns_items ri
    left join return_order_item_net roin
      on roin.order_id = ri.order_id
     and roin.item_id_text = ri.item_id_text
  ),
  return_scaling as (
    select
      rigv.return_id,
      max(rigv.return_amount) as return_amount,
      sum(rigv.gross_value) as gross_value_sum
    from return_item_gross_value rigv
    group by rigv.return_id
  ),
  returns_sales as (
    select
      rigv.item_id_text,
      sum(rigv.qty_returned) as qty_returned,
      sum(
        (
          case
            when rs.gross_value_sum > 0
              then rigv.gross_value * (rs.return_amount / rs.gross_value_sum)
            else 0
          end
        ) * coalesce(rb.fx_rate, 1)
      ) as returned_sales
    from return_item_gross_value rigv
    join return_scaling rs on rs.return_id = rigv.return_id
    join returns_base rb on rb.return_id = rigv.return_id
    group by rigv.item_id_text
  ),
  returns_qty_base as (
    select
      nri.item_id_text,
      sum(
        case
          when nri.unit_type in ('kg', 'gram') and nri.weight > 0
            then greatest(nri.weight * greatest(nri.quantity, 1), 0)
          else greatest(nri.quantity, 0) * greatest(coalesce(nri.uom_qty_in_base, 1), 1)
        end
      ) as qty_returned_base
    from normalized_return_items nri
    where nullif(nri.item_id_text,'') is not null
    group by nri.item_id_text
  ),
  returns_cost as (
    select
      im.item_id::text as item_id_text,
      sum(im.quantity) as qty_returned_cost,
      sum(im.total_cost) as returned_cost
    from public.inventory_movements im
    where im.reference_table = 'sales_returns'
      and im.movement_type = 'return_in'
      and im.occurred_at >= p_start_date
      and im.occurred_at <= p_end_date
      and (
        p_zone_id is null or exists (
          select 1 from public.orders o
          where o.id = (im.data->>'orderId')::uuid
            and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
            and coalesce(
              o.delivery_zone_id,
              case
                when nullif(o.data->>'deliveryZoneId','') is not null
                     and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{12}$'
                  then (o.data->>'deliveryZoneId')::uuid
                else null
              end
            ) = p_zone_id
        )
      )
    group by im.item_id::text
  ),
  cogs_recorded as (
    select
      oic.item_id::text as item_id_text,
      sum(oic.total_cost) as recorded_cost,
      sum(oic.quantity) as recorded_qty
    from public.order_item_cogs oic
    join sales_orders so on so.id = oic.order_id
    group by oic.item_id::text
  ),
  period_movements as (
    select
      im.item_id::text as item_id_text,
      sum(case when im.movement_type in ('purchase_in','adjust_in','return_in') then im.quantity else 0 end)
      -
      sum(case when im.movement_type in ('sale_out','wastage_out','adjust_out','return_out') then im.quantity else 0 end)
      as net_qty_period
    from public.inventory_movements im
    where im.occurred_at >= p_start_date
      and im.occurred_at <= p_end_date
    group by im.item_id::text
  ),
  stock_agg as (
    select
      sm.item_id::text as item_id_text,
      coalesce(sum(sm.available_quantity), 0) as available_quantity,
      coalesce(sum(sm.reserved_quantity), 0) as reserved_quantity,
      case
        when coalesce(sum(sm.available_quantity), 0) > 0
          then coalesce(sum(sm.avg_cost * sm.available_quantity) / nullif(sum(sm.available_quantity), 0), 0)
        else coalesce(avg(sm.avg_cost), 0)
      end as avg_cost
    from public.stock_management sm
    group by sm.item_id::text
  ),
  item_keys as (
    select item_id_text from sales_lines
    union
    select item_id_text from returns_sales
    union
    select item_id_text from returns_cost
    union
    select item_id_text from cogs_recorded
  )
  select
    k.item_id_text as item_id,
    coalesce(mi.data->'name', sl.any_name, jsonb_build_object('ar', k.item_id_text)) as item_name,
    coalesce(nullif(mi.unit_type, ''), nullif(sl.any_unit, ''), 'piece') as unit_type,
    greatest(coalesce(sl.qty_sold, 0) - coalesce(rs.qty_returned, 0), 0) as quantity_sold,
    greatest(coalesce(sl.net_sales, 0) - coalesce(rs.returned_sales, 0), 0) as total_sales,
    greatest(
      coalesce(
        cr.recorded_cost,
        coalesce(sa.avg_cost, mi.cost_price, 0)
          * greatest(coalesce(sl.qty_base, 0) - coalesce(rqb.qty_returned_base, 0), 0)
      )
      - coalesce(rc.returned_cost, 0),
      0
    ) as total_cost,
    (
      greatest(coalesce(sl.net_sales, 0) - coalesce(rs.returned_sales, 0), 0)
      - greatest(
          coalesce(
            cr.recorded_cost,
            coalesce(sa.avg_cost, mi.cost_price, 0)
              * greatest(coalesce(sl.qty_base, 0) - coalesce(rqb.qty_returned_base, 0), 0)
          )
          - coalesce(rc.returned_cost, 0),
          0
        )
    ) as total_profit,
    coalesce(sa.available_quantity, 0) as current_stock,
    coalesce(sa.reserved_quantity, 0) as reserved_stock,
    coalesce(sa.avg_cost, mi.cost_price, 0) as current_cost_price,
    (
      (
        greatest(
          coalesce(sa.available_quantity, 0) - coalesce(pm.net_qty_period, 0),
          0
        )
        + coalesce(sa.available_quantity, 0)
      ) / 2.0
    ) as avg_inventory
  from item_keys k
  left join public.menu_items mi on mi.id::text = k.item_id_text
  left join sales_lines sl on sl.item_id_text = k.item_id_text
  left join returns_sales rs on rs.item_id_text = k.item_id_text
  left join returns_cost rc on rc.item_id_text = k.item_id_text
  left join returns_qty_base rqb on rqb.item_id_text = k.item_id_text
  left join stock_agg sa on sa.item_id_text = k.item_id_text
  left join period_movements pm on pm.item_id_text = k.item_id_text
  left join cogs_recorded cr on cr.item_id_text = k.item_id_text
  where (coalesce(sl.qty_sold, 0) + coalesce(rs.qty_returned, 0)) > 0
  order by total_sales desc;
end;
$$;

revoke all on function public.get_product_sales_report_v9(timestamptz, timestamptz, uuid, boolean) from public;
grant execute on function public.get_product_sales_report_v9(timestamptz, timestamptz, uuid, boolean) to authenticated;

create or replace function public.get_sales_report_summary(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_zone_id uuid default null,
  p_invoice_only boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_total_collected numeric := 0;
  v_total_tax numeric := 0;
  v_total_delivery numeric := 0;
  v_total_discounts numeric := 0;
  v_total_returns numeric := 0;
  v_total_cogs numeric := 0;
  v_total_returns_cogs numeric := 0;
  v_total_wastage numeric := 0;
  v_total_expenses numeric := 0;
  v_total_delivery_cost numeric := 0;

  v_total_orders integer := 0;
  v_delivered_orders integer := 0;
  v_cancelled_orders integer := 0;
  v_out_for_delivery integer := 0;
  v_in_store integer := 0;
  v_online integer := 0;

begin
  if p_start_date is null or p_end_date is null then
    raise exception 'start_date and end_date are required';
  end if;

  with effective_orders as (
    select o.*
    from public.orders o
    where o.status in ('delivered','cancelled','out_for_delivery')
      and o.created_at between p_start_date and p_end_date
      and (p_zone_id is null or o.delivery_zone_id = p_zone_id)
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
  )
  select
    count(*)::int as total_orders,
    count(*) filter (where status = 'delivered')::int as delivered_orders,
    count(*) filter (where status = 'cancelled')::int as cancelled_orders,
    count(*) filter (where status = 'out_for_delivery')::int as out_for_delivery,
    count(*) filter (where coalesce(nullif(data->>'orderSource',''), '') = 'in_store')::int as in_store,
    count(*) filter (where coalesce(nullif(data->>'orderSource',''), '') <> 'in_store')::int as online
  into v_total_orders, v_delivered_orders, v_cancelled_orders, v_out_for_delivery, v_in_store, v_online
  from effective_orders;

  with effective_orders as (
    select
      o.*,
      public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        o.created_at,
        o.fx_rate
      ) as fx_rate_effective
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (p_zone_id is null or o.delivery_zone_id = p_zone_id)
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
  )
  select
    coalesce(sum(coalesce(o.base_total, coalesce(nullif((o.data->>'total')::numeric, null), o.total, 0) * coalesce(o.fx_rate_effective, 1))), 0),
    coalesce(sum(coalesce(nullif((o.data->>'taxAmount')::numeric, null), o.tax_amount, 0) * coalesce(o.fx_rate_effective, 1)), 0),
    coalesce(sum(coalesce(nullif((o.data->>'deliveryFee')::numeric, null), 0) * coalesce(o.fx_rate_effective, 1)), 0),
    coalesce(sum(coalesce(nullif((o.data->>'discountAmount')::numeric, null), o.discount, 0) * coalesce(o.fx_rate_effective, 1)), 0)
  into v_total_collected, v_total_tax, v_total_delivery, v_total_discounts
  from effective_orders o;

  with effective_orders as (
    select
      o.id,
      public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        o.created_at,
        o.fx_rate
      ) as fx_rate_effective
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (p_zone_id is null or o.delivery_zone_id = p_zone_id)
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
  )
  select coalesce(sum(sr.total_refund_amount * coalesce(eo.fx_rate_effective, 1)), 0)
  into v_total_returns
  from public.sales_returns sr
  join effective_orders eo on eo.id = sr.order_id
  where sr.status = 'completed';

  with effective_orders as (
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (p_zone_id is null or o.delivery_zone_id = p_zone_id)
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
  )
  select coalesce(sum(oic.total_cost), 0)
  into v_total_cogs
  from public.order_item_cogs oic
  join effective_orders eo on eo.id = oic.order_id;

  if coalesce(v_total_cogs, 0) <= 0 then
    with effective_orders as (
      select o.id
      from public.orders o
      where o.status = 'delivered'
        and o.created_at between p_start_date and p_end_date
        and (p_zone_id is null or o.delivery_zone_id = p_zone_id)
        and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
    )
    select
      coalesce(sum(coalesce(nullif(im.total_cost, 0), im.quantity * coalesce(nullif(b.unit_cost, 0), 0))), 0)
    into v_total_cogs
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    join effective_orders eo on eo.id::text = im.reference_id
    where im.reference_table = 'orders'
      and im.movement_type = 'sale_out'
      and im.batch_id is not null
      and im.occurred_at between p_start_date and p_end_date;
  end if;

  with effective_orders as (
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (p_zone_id is null or o.delivery_zone_id = p_zone_id)
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
  )
  select coalesce(sum(coalesce(nullif(im.total_cost, 0), im.quantity * coalesce(nullif(b.unit_cost, 0), 0))), 0)
  into v_total_returns_cogs
  from public.inventory_movements im
  join public.batches b on b.id = im.batch_id
  join public.sales_returns sr on sr.id::text = im.reference_id
  join effective_orders eo on eo.id = sr.order_id
  where im.reference_table = 'sales_returns'
    and im.movement_type = 'return_in'
    and im.batch_id is not null
    and sr.status = 'completed'
    and im.occurred_at between p_start_date and p_end_date;

  select coalesce(sum(w.cost_amount), 0)
  into v_total_wastage
  from public.wastage_records w
  where w.status = 'approved'
    and w.created_at between p_start_date and p_end_date
    and (p_zone_id is null or w.zone_id = p_zone_id);

  select coalesce(sum(e.amount), 0)
  into v_total_expenses
  from public.expenses e
  where e.status = 'approved'
    and e.created_at between p_start_date and p_end_date
    and (p_zone_id is null or e.zone_id = p_zone_id);

  begin
    select coalesce(sum(dc.cost_amount), 0)
    into v_total_delivery_cost
    from public.delivery_costs dc
    where dc.created_at between p_start_date and p_end_date
      and (p_zone_id is null or dc.zone_id = p_zone_id);
  exception when others then
    v_total_delivery_cost := 0;
  end;

  v_result := jsonb_build_object(
    'total_collected', public._money_round(v_total_collected),
    'gross_subtotal', public._money_round(greatest(v_total_collected - v_total_tax - v_total_delivery + v_total_discounts, 0)),
    'returns', public._money_round(v_total_returns),
    'discounts', public._money_round(v_total_discounts),
    'tax', public._money_round(v_total_tax),
    'delivery_fees', public._money_round(v_total_delivery),
    'delivery_cost', public._money_round(v_total_delivery_cost),
    'cogs', public._money_round(greatest(v_total_cogs - v_total_returns_cogs, 0)),
    'wastage', public._money_round(v_total_wastage),
    'expenses', public._money_round(v_total_expenses),
    'total_orders', v_total_orders,
    'delivered_orders', v_delivered_orders,
    'cancelled_orders', v_cancelled_orders,
    'out_for_delivery_count', v_out_for_delivery,
    'in_store_count', v_in_store,
    'online_count', v_online,
    'total_orders_accrual', v_total_orders,
    'delivered_count_accrual', v_delivered_orders,
    'cancelled_count_accrual', v_cancelled_orders,
    'out_for_delivery_count_accrual', v_out_for_delivery,
    'in_store_count_accrual', v_in_store,
    'online_count_accrual', v_online
  );

  return v_result;
end;
$$;

revoke all on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from public;
revoke execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from anon;
grant execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) to authenticated;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
