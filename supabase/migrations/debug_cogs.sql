with eligible_orders as (
    select id, data
    from public.orders
    where created_at >= now() - interval '30 days'
      and (status = 'delivered' or data->>'paidAt' is not null)
),
oic as (
    select coalesce(sum(o.total_cost), 0) as val 
    from public.order_item_cogs o 
    join eligible_orders eo on eo.id = o.order_id
),
im as (
    select coalesce(sum(im.total_cost), 0) as val 
    from public.inventory_movements im
    join eligible_orders eo on eo.id = (im.reference_id)::uuid
    where im.reference_table = 'orders' and im.movement_type = 'sale_out'
),
est as (
    select
        sum(
          coalesce(q.qty, 0)
          * coalesce(nullif(sm.avg_cost, 0), nullif(mi.cost_price, 0), nullif(mi.buying_price, 0), 0)
        ) as val
      from eligible_orders eo
      cross join lateral (
        select
          coalesce(
            nullif(btrim(coalesce(it->>'itemId', '')), ''),
            nullif(btrim(coalesce(it->>'menuItemId', '')), ''),
            nullif(btrim(coalesce(it->>'id', '')), '')
          ) as item_id,
          case
            when lower(coalesce(it->>'unitType', '')) in ('gram','kg')
                 and nullif(btrim(coalesce(it->>'weight', '')), '') is not null
              then coalesce(public.safe_cast_numeric(it->>'weight'), 0)
            else coalesce(public.safe_cast_numeric(it->>'quantity'), 0)
                 * coalesce(public.safe_cast_numeric(it->>'uomQtyInBase'), public.safe_cast_numeric(it->>'uom_qty_in_base'), 1)
          end as qty
        from jsonb_array_elements(
          case
            when jsonb_typeof(eo.data->'invoiceSnapshot'->'items') = 'array'
                 and jsonb_array_length(eo.data->'invoiceSnapshot'->'items') > 0
              then eo.data->'invoiceSnapshot'->'items'
            when jsonb_typeof(eo.data->'items') = 'array'
              then eo.data->'items'
            else '[]'::jsonb
          end
        ) as it
      ) q
      left join public.menu_items mi on mi.id::text = q.item_id::text
      left join public.stock_management sm on sm.item_id::text = q.item_id::text
      where q.item_id is not null and q.qty > 0
)
select 
    (select count(*) from eligible_orders) as num_orders,
    (select val from oic) as order_item_cogs_total,
    (select val from im) as inventory_movements_cogs_total,
    (select val from est) as estimated_cogs_total;
