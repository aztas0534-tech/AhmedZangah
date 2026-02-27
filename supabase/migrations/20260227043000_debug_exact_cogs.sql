do $$
declare
  v_start timestamptz := now() - interval '30 days';
  v_end timestamptz := now();
  v_total_cogs numeric := 0;
begin
  raise notice '==================================================';
  raise notice 'RUNNING EXACT COGS QUERY';

  begin
    with eligible_orders as (
      select id from public.orders
      where created_at >= v_start and created_at <= v_end
        and (status = 'delivered' or data->>'paidAt' is not null)
    ),
    oic_by_order as (
      select oic.order_id, sum(coalesce(oic.total_cost, 0)) as total_cost
      from public.order_item_cogs oic
      join eligible_orders eo on eo.id = oic.order_id
      group by oic.order_id
    ),
    im_by_order as (
      select
        (im.reference_id)::uuid as order_id,
        sum(
          coalesce(
            nullif(im.total_cost, 0),
            coalesce(im.quantity, 0) * coalesce(nullif(b.unit_cost, 0), nullif(im.unit_cost, 0), 0)
          )
        ) as total_cost
      from public.inventory_movements im
      left join public.batches b on b.id = im.batch_id
      join eligible_orders eo on eo.id = (im.reference_id)::uuid
      where im.reference_table = 'orders'
        and im.movement_type = 'sale_out'
        and im.reference_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      group by (im.reference_id)::uuid
    ),
    est_by_order as (
      select
        o.id as order_id,
        sum(
          coalesce(q.qty, 0)
          * coalesce(nullif(sm.avg_cost, 0), nullif(mi.cost_price, 0), nullif(mi.buying_price, 0), 0)
        ) as total_cost
      from public.orders o
      join eligible_orders eo on eo.id = o.id
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
            when jsonb_typeof(o.data->'invoiceSnapshot'->'items') = 'array'
                 and jsonb_array_length(o.data->'invoiceSnapshot'->'items') > 0
              then o.data->'invoiceSnapshot'->'items'
            when jsonb_typeof(o.data->'items') = 'array'
              then o.data->'items'
            else '[]'::jsonb
          end
        ) as it
      ) q
      left join public.menu_items mi on mi.id::text = q.item_id::text
      left join public.stock_management sm
        on sm.item_id::text = q.item_id::text
       and sm.warehouse_id = o.warehouse_id
      where q.item_id is not null and q.qty > 0
      group by o.id
    )
    select coalesce(sum(
      coalesce(
        nullif(oic.total_cost, 0),
        nullif(im.total_cost, 0),
        coalesce(est.total_cost, 0)
      )
    ), 0)
    into v_total_cogs
    from eligible_orders eo
    left join oic_by_order oic on oic.order_id = eo.id
    left join im_by_order im on im.order_id = eo.id
    left join est_by_order est on est.order_id = eo.id;

    raise notice 'EXACT QUERY SUCCESS: COGS = %', v_total_cogs;

  exception when others then
    raise notice 'EXACT QUERY FAILED: %', sqlerrm;
    raise notice 'HINT: %', SQLSTATE;
  end;

  raise notice '==================================================';
end $$;
