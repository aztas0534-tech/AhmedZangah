do $$
declare
    v_start timestamptz := now() - interval '30 days';
    v_end timestamptz := now();
    v_products json;
begin
    raise notice '==================================================';
    raise notice 'TESTING TOP PRODUCTS INTERNAL QUERY';
    
    with effective_orders as (
      select
        o.id,
        o.data,
        o.status,
        o.payment_method,
        nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
        coalesce(
            nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
            nullif(o.data->>'paidAt', '')::timestamptz,
            nullif(o.data->>'deliveredAt', '')::timestamptz,
            nullif(o.data->>'closedAt', '')::timestamptz,
            o.created_at
        ) as date_by,
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
      where nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
    ),
    sales_orders as (
      select
        eo.*,
        public.order_fx_rate(eo.currency_code, eo.date_by, eo.fx_rate_raw) as fx_rate
      from effective_orders eo
      where (eo.paid_at is not null or eo.status = 'delivered')
        and eo.date_by >= v_start
        and eo.date_by <= v_end
    )
    select json_agg(t) into v_products from (
        select count(*) as cnt from sales_orders
    ) t;

    raise notice 'Sales Orders count: %', v_products;
    
    raise notice '==================================================';
end $$;
