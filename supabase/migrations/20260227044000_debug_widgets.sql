do $$
declare
    v_products json;
    v_stock json;
    v_start timestamptz := now() - interval '30 days';
    v_end timestamptz := now();
begin
    raise notice '==================================================';
    raise notice 'TESTING DASHBOARD WIDGETS API';
    
    begin
        select json_agg(t) into v_products from (
            select * from public.get_product_sales_report_v9(v_start, v_end, null)
            order by total_sales desc limit 5
        ) t;
        raise notice 'Top Products JSON output: %', coalesce(v_products::text, 'NULL');
    exception when others then
        raise notice 'Top Products ERROR: %', sqlerrm;
    end;

    begin
        select json_agg(t) into v_stock from (
            select * from public.get_inventory_stock_report(null, null, 100)
        ) t;
        raise notice 'Stock Report JSON output length: %', length(coalesce(v_stock::text, ''));
        raise notice 'Stock Report Sample: %', left(coalesce(v_stock::text, ''), 200);
    exception when others then
        raise notice 'Stock Report ERROR: %', sqlerrm;
    end;

    raise notice '==================================================';
end $$;
