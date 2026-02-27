do $$
declare
    v_start timestamptz := now() - interval '30 days';
    v_end timestamptz := now();
    v_products json;
    v_zone_id uuid := null;
    v_invoice_only boolean := false;
begin
    raise notice '==================================================';
    raise notice 'TESTING ENTIRE TOP PRODUCTS QUERY';
    
    begin
        select json_agg(t) into v_products from (
          -- Paste the massive query here
          with effective_orders as (
            select
              o.id,
              o.data,
              o.status,
              o.payment_method,
              nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
              case
                when v_invoice_only
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
            where (v_zone_id is null or coalesce(
              o.delivery_zone_id,
              case
                when nullif(o.data->>'deliveryZoneId','') is not null
                    and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{12}$'
                  then (o.data->>'deliveryZoneId')::uuid
                else null
              end
            ) = v_zone_id)
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
              and eo.date_by >= v_start
              and eo.date_by <= v_end
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
          )
          select item_id_text, any_name, qty_sold, net_sales
          from sales_lines
          limit 5
        ) t;

        raise notice 'Sales Line Output: %', v_products;
    exception when others then
        raise notice 'ERROR: % - %', SQLSTATE, sqlerrm;
    end;

    raise notice '==================================================';
end $$;
