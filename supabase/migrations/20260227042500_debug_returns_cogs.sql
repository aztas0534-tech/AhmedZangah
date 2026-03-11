do $$
declare
  v_oic_cogs numeric := 0;
  v_im_cogs numeric := 0;
  v_est_cogs numeric := 0;
  v_start timestamptz := now() - interval '30 days';
  v_end timestamptz := now();
  v_orders_count int := 0;
begin
  raise notice '==================================================';
  raise notice 'STARTING COGS DEBUG ANALYSIS (Last 30 days)';

  -- 1. Get eligible orders count
  select count(*) into v_orders_count
  from public.orders
  where created_at >= v_start and created_at <= v_end
    and (status = 'delivered' or data->>'paidAt' is not null);
  
  raise notice 'Eligible Orders Count: %', v_orders_count;

  -- 2. Check Order Item COGS (OIC)
  begin
    with eligible_orders as (
      select id from public.orders
      where created_at >= v_start and created_at <= v_end
        and (status = 'delivered' or data->>'paidAt' is not null)
    )
    select coalesce(sum(oic.total_cost), 0) into v_oic_cogs
    from public.order_item_cogs oic
    join eligible_orders eo on eo.id = oic.order_id;
    
    raise notice 'OIC Total Cost: %', v_oic_cogs;
  exception when others then
    raise notice 'OIC Calculation Error: %', sqlerrm;
  end;

  -- 3. Check Inventory Movements (IM)
  begin
    with eligible_orders as (
      select id from public.orders
      where created_at >= v_start and created_at <= v_end
        and (status = 'delivered' or data->>'paidAt' is not null)
    )
    select coalesce(sum(
      coalesce(
        nullif(im.total_cost, 0),
        coalesce(im.quantity, 0) * coalesce(nullif(b.unit_cost, 0), nullif(im.unit_cost, 0), 0)
      )
    ), 0) into v_im_cogs
    from public.inventory_movements im
    left join public.batches b on b.id = im.batch_id
    join eligible_orders eo on eo.id = (im.reference_id)::uuid
    where im.reference_table = 'orders'
      and im.movement_type = 'sale_out';
      
    raise notice 'Inventory Movements Total Cost: %', v_im_cogs;
  exception when others then
    raise notice 'IM Calculation Error: %', sqlerrm;
  end;

  -- 4. Check Estimation (Est)
  begin
    with eligible_orders as (
      select id, data, warehouse_id from public.orders
      where created_at >= v_start and created_at <= v_end
        and (status = 'delivered' or data->>'paidAt' is not null)
    )
    select coalesce(sum(
          coalesce(q.qty, 0)
          * coalesce(nullif(sm.avg_cost, 0), nullif(mi.cost_price, 0), nullif(mi.buying_price, 0), 0)
    ), 0) into v_est_cogs
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
    left join public.stock_management sm
        on sm.item_id::text = q.item_id::text
       and sm.warehouse_id = eo.warehouse_id
    where q.item_id is not null and q.qty > 0;
    
    raise notice 'Estimated Fallback Total Cost: %', v_est_cogs;
  exception when others then
    raise notice 'Estimation Calculation Error: %', sqlerrm;
  end;

  -- 5. Check Returns COGS
  declare
    v_returns_cogs numeric := 0;
  begin
    with eligible_orders as (
      select id from public.orders
      where created_at >= v_start and created_at <= v_end
        and (status = 'delivered' or data->>'paidAt' is not null)
    )
    select coalesce(sum(coalesce(nullif(im.total_cost, 0), im.quantity * coalesce(nullif(b.unit_cost, 0), 0))), 0)
    into v_returns_cogs
    from public.inventory_movements im
    join public.batches b on b.id = im.batch_id
    join public.sales_returns sr on sr.id::text = im.reference_id
    join eligible_orders eo on eo.id = sr.order_id
    where im.reference_table = 'sales_returns'
      and im.movement_type = 'return_in'
      and im.batch_id is not null
      and sr.status = 'completed';
    
    raise notice 'Returns COGS Total: %', v_returns_cogs;
  exception when others then
    raise notice 'Returns COGS Error: %', sqlerrm;
  end;

  raise notice '==================================================';
end $$;
