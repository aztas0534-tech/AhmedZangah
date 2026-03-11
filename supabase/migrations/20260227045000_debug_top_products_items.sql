do $$
declare
    v_items json;
begin
    raise notice '==================================================';
    raise notice 'CHECKING RAW ORDER ITEMS';
    
    with items as (
      select id, data->'items' as items_arr
      from public.orders
      where data->'items' is not null
      limit 2
    )
    select json_agg(t) into v_items from items t;

    raise notice 'Sample JSON items: %', v_items;

    with items2 as (
      select id, data->'invoiceSnapshot'->'items' as items_arr
      from public.orders
      where data->'invoiceSnapshot'->'items' is not null
      limit 2
    )
    select json_agg(t) into v_items from items2 t;

    raise notice 'Sample JSON invoiceSnapshot items: %', v_items;

    raise notice '==================================================';
end $$;
