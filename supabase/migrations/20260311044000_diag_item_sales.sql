-- Focused diagnostic: water item sales data
create or replace function public.diag_item_sales(p_item_id text default 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb := '{}'::jsonb;
begin
  -- 1. Item pricing info
  select jsonb_build_object(
    'name', mi.data->'name', 'base_unit', mi.base_unit, 'unit_type', mi.unit_type,
    'buying_price', mi.buying_price,
    'cost_price', mi.cost_price, 'category', mi.category,
    'data_price', mi.data->'price', 'data_prices', mi.data->'prices',
    'data_all', mi.data
  ) into v from public.menu_items mi where mi.id::text = p_item_id;

  -- 2. All orders containing this item (from order_items table)
  v := v || jsonb_build_object('order_items', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'order_id', oi.order_id, 'quantity', oi.quantity, 'unit_price', oi.unit_price,
      'total_price', oi.total_price, 'unit_type', oi.unit_type,
      'order_status', o.status, 'order_date', o.created_at::text,
      'order_currency', o.currency, 'order_fx_rate', o.fx_rate
    ) order by o.created_at), '[]'::jsonb)
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where oi.item_id::text = p_item_id
  ));

  -- 3. order_item_cogs for this item
  v := v || jsonb_build_object('order_item_cogs', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'order_id', oic.order_id, 'item_id', oic.item_id,
      'quantity', oic.quantity, 'unit_cost', oic.unit_cost,
      'total_cost', oic.total_cost, 'batch_id', left(oic.batch_id::text, 8),
      'order_status', o.status, 'order_date', o.created_at::text
    ) order by o.created_at), '[]'::jsonb)
    from public.order_item_cogs oic
    join public.orders o on o.id = oic.order_id
    where oic.item_id::text = p_item_id
  ));

  -- 4. sale_out movements
  v := v || jsonb_build_object('sale_out_movements', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', im.id, 'quantity', im.quantity, 'unit_cost', im.unit_cost,
      'total_cost', im.total_cost, 'batch_id', left(im.batch_id::text, 8),
      'occurred_at', im.occurred_at::text,
      'ref_id', left(im.reference_id, 8)
    ) order by im.occurred_at), '[]'::jsonb)
    from public.inventory_movements im
    where im.item_id::text = p_item_id and im.movement_type = 'sale_out'
  ));

  -- 5. All movement types summary
  v := v || jsonb_build_object('movement_summary', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'type', x.mt, 'count', x.cnt, 'total_qty', x.tq, 'total_cost', x.tc
    )), '[]'::jsonb)
    from (select im.movement_type as mt, count(*) as cnt, sum(im.quantity) as tq, sum(im.total_cost) as tc
          from public.inventory_movements im where im.item_id::text = p_item_id group by im.movement_type) x
  ));

  -- 6. UOM info
  v := v || jsonb_build_object('uom', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'uom_id', iu.uom_id, 'base_uom_id', iu.base_uom_id,
      'conversion_factor', iu.conversion_factor,
      'uom_name', u.name_ar, 'uom_code', u.code
    )), '[]'::jsonb)
    from public.item_uom iu
    left join public.uom u on u.id = iu.uom_id
    where iu.item_id::text = p_item_id
  ));

  return v;
end; $$;
grant execute on function public.diag_item_sales(text) to authenticated;
notify pgrst, 'reload schema';
