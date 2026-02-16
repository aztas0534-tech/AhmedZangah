-- Fix: column "sr.return_date" must appear in the GROUP BY clause
-- Bug: returns_base CTE in get_sales_report_summary uses sr.return_date
-- in SELECT expressions but only groups by (o.id, o.data, o.fx_rate).

create or replace function public.get_sales_report_summary(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_zone_id uuid default null,
  p_invoice_only boolean default false
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_collected numeric := 0;
  v_total_tax numeric := 0;
  v_total_delivery numeric := 0;
  v_total_discounts numeric := 0;
  v_gross_subtotal numeric := 0;
  v_total_orders integer := 0;
  v_cancelled_orders integer := 0;
  v_delivered_orders integer := 0;
  v_total_returns numeric := 0;
  v_total_cogs numeric := 0;
  v_total_returns_cogs numeric := 0;
  v_total_wastage numeric := 0;
  v_total_expenses numeric := 0;
  v_total_delivery_cost numeric := 0;
  v_out_for_delivery integer := 0;
  v_in_store integer := 0;
  v_online integer := 0;
  v_tax_refunds numeric := 0;
  v_result json;
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;

  with effective_orders as (
    select
      o.id,
      o.status,
      o.created_at,
      coalesce(nullif(o.data->>'paymentMethod', ''), '') as payment_method,
      nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
      public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        case
          when p_invoice_only
            then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
          else coalesce(
            nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
            nullif(o.data->>'paidAt', '')::timestamptz,
            nullif(o.data->>'deliveredAt', '')::timestamptz,
            o.created_at
          )
        end,
        o.fx_rate
      ) as fx_rate,
      case
        when p_invoice_only
          then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
        else coalesce(
          nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
          nullif(o.data->>'paidAt', '')::timestamptz,
          nullif(o.data->>'deliveredAt', '')::timestamptz,
          o.created_at
        )
      end as date_by,
      coalesce(
        o.base_total,
        coalesce(nullif((o.data->>'total')::numeric, null), 0) * public.order_fx_rate(
          coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
          case
            when p_invoice_only
              then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
            else coalesce(
              nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
              nullif(o.data->>'paidAt', '')::timestamptz,
              nullif(o.data->>'deliveredAt', '')::timestamptz,
              o.created_at
            )
          end,
          o.fx_rate
        )
      ) as total,
      (coalesce(nullif((o.data->>'taxAmount')::numeric, null), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        case
          when p_invoice_only
            then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
          else coalesce(
            nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
            nullif(o.data->>'paidAt', '')::timestamptz,
            nullif(o.data->>'deliveredAt', '')::timestamptz,
            o.created_at
          )
        end,
        o.fx_rate
      )) as tax_amount,
      (coalesce(nullif((o.data->>'deliveryFee')::numeric, null), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        case
          when p_invoice_only
            then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
          else coalesce(
            nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
            nullif(o.data->>'paidAt', '')::timestamptz,
            nullif(o.data->>'deliveredAt', '')::timestamptz,
            o.created_at
          )
        end,
        o.fx_rate
      )) as delivery_fee,
      (coalesce(nullif((o.data->>'discountAmount')::numeric, null), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        case
          when p_invoice_only
            then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
          else coalesce(
            nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
            nullif(o.data->>'paidAt', '')::timestamptz,
            nullif(o.data->>'deliveredAt', '')::timestamptz,
            o.created_at
          )
        end,
        o.fx_rate
      )) as discount_amount,
      (coalesce(nullif((o.data->>'subtotal')::numeric, null), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        case
          when p_invoice_only
            then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
          else coalesce(
            nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
            nullif(o.data->>'paidAt', '')::timestamptz,
            nullif(o.data->>'deliveredAt', '')::timestamptz,
            o.created_at
          )
        end,
        o.fx_rate
      )) as subtotal,
      coalesce(
        o.delivery_zone_id,
        case
          when nullif(o.data->>'deliveryZoneId','') is not null
               and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (o.data->>'deliveryZoneId')::uuid
          else null
        end
      ) as zone_effective
    from public.orders o
    where (p_zone_id is null or coalesce(
      o.delivery_zone_id,
      case
        when nullif(o.data->>'deliveryZoneId','') is not null
             and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (o.data->>'deliveryZoneId')::uuid
        else null
      end
    ) = p_zone_id)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  )
  select
    coalesce(sum(eo.total), 0),
    coalesce(sum(eo.tax_amount), 0),
    coalesce(sum(eo.delivery_fee), 0),
    coalesce(sum(eo.discount_amount), 0),
    coalesce(sum(eo.subtotal), 0),
    count(*),
    count(*) filter (where eo.status = 'delivered')
  into
    v_total_collected,
    v_total_tax,
    v_total_delivery,
    v_total_discounts,
    v_gross_subtotal,
    v_total_orders,
    v_delivered_orders
  from effective_orders eo
  where (
      eo.paid_at is not null
      or (eo.status = 'delivered' and eo.payment_method <> 'cash')
  )
    and eo.date_by >= p_start_date
    and eo.date_by <= p_end_date;

  with effective_orders as (
    select
      o.id,
      o.status,
      case
        when p_invoice_only
          then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
        else coalesce(
          nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
          nullif(o.data->>'paidAt', '')::timestamptz,
          nullif(o.data->>'deliveredAt', '')::timestamptz,
          o.created_at
        )
      end as date_by,
      coalesce(
        o.delivery_zone_id,
        case
          when nullif(o.data->>'deliveryZoneId','') is not null
               and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (o.data->>'deliveryZoneId')::uuid
          else null
        end
      ) as zone_effective
    from public.orders o
    where (p_zone_id is null or coalesce(
      o.delivery_zone_id,
      case
        when nullif(o.data->>'deliveryZoneId','') is not null
             and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (o.data->>'deliveryZoneId')::uuid
        else null
      end
    ) = p_zone_id)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  )
  select count(*)
  into v_cancelled_orders
  from effective_orders eo
  where eo.status = 'cancelled'
    and eo.date_by >= p_start_date
    and eo.date_by <= p_end_date;

  -- FIX: Added sr.return_date to GROUP BY to resolve:
  --   column "sr.return_date" must appear in the GROUP BY clause
  with returns_base as (
    select
      public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      ) as fx_rate,
      (coalesce(nullif((o.data->>'subtotal')::numeric, null), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      )) as order_subtotal,
      (coalesce(nullif((o.data->>'discountAmount')::numeric, null), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      )) as order_discount,
      greatest(
        (coalesce(nullif((o.data->>'subtotal')::numeric, null), 0) * public.order_fx_rate(
          coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
          sr.return_date,
          o.fx_rate
        ))
        - (coalesce(nullif((o.data->>'discountAmount')::numeric, null), 0) * public.order_fx_rate(
          coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
          sr.return_date,
          o.fx_rate
        )),
        0
      ) as order_net_subtotal,
      (coalesce(nullif((o.data->>'taxAmount')::numeric, null), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      )) as order_tax,
      (coalesce(sum(coalesce(nullif((i->>'quantity')::numeric, null), 0) * coalesce(nullif((i->>'unitPrice')::numeric, null), 0)), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      )) as return_subtotal,
      (coalesce(sum(sr.total_refund_amount), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      )) as total_refund_amount
    from public.sales_returns sr
    join public.orders o on o.id::text = sr.order_id::text
    cross join lateral jsonb_array_elements(coalesce(sr.items, '[]'::jsonb)) i
    where sr.status = 'completed'
      and sr.return_date >= p_start_date
      and sr.return_date <= p_end_date
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
      and (p_zone_id is null or coalesce(
        o.delivery_zone_id,
        case
          when nullif(o.data->>'deliveryZoneId','') is not null
               and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (o.data->>'deliveryZoneId')::uuid
          else null
        end
      ) = p_zone_id)
    group by o.id, o.data, o.fx_rate, o.currency, sr.return_date
  )
  select
    coalesce(sum(total_refund_amount), 0),
    coalesce(sum(
      case
        when order_net_subtotal > 0 and order_tax > 0
          then least(order_tax, (return_subtotal / order_net_subtotal) * order_tax)
        else 0
      end
    ), 0)
  into v_total_returns, v_tax_refunds
  from returns_base;

  v_total_tax := greatest(v_total_tax - v_tax_refunds, 0);

  with effective_orders as (
    select
      o.id,
      o.status,
      coalesce(nullif(o.data->>'paymentMethod', ''), '') as payment_method,
      nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
      case
        when p_invoice_only
          then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
        else coalesce(
          nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
          nullif(o.data->>'paidAt', '')::timestamptz,
          nullif(o.data->>'deliveredAt', '')::timestamptz,
          o.created_at
        )
      end as date_by
    from public.orders o
    where (p_zone_id is null or coalesce(
      o.delivery_zone_id,
      case
        when nullif(o.data->>'deliveryZoneId','') is not null
             and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (o.data->>'deliveryZoneId')::uuid
        else null
      end
    ) = p_zone_id)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  )
  select coalesce(sum(oic.total_cost), 0)
  into v_total_cogs
  from public.order_item_cogs oic
  join effective_orders eo on oic.order_id = eo.id
  where (
      eo.paid_at is not null
      or (eo.status = 'delivered' and eo.payment_method <> 'cash')
  )
    and eo.date_by >= p_start_date
    and eo.date_by <= p_end_date;

  select coalesce(sum(im.total_cost), 0)
  into v_total_returns_cogs
  from public.inventory_movements im
  where im.reference_table = 'sales_returns'
    and im.movement_type = 'return_in'
    and im.occurred_at >= p_start_date
    and im.occurred_at <= p_end_date
    and (
      p_zone_id is null or exists (
        select 1 from public.orders o
        where o.id::text = (im.data->>'orderId')
          and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
          and coalesce(
            o.delivery_zone_id,
            case
              when nullif(o.data->>'deliveryZoneId','') is not null
                   and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                then (o.data->>'deliveryZoneId')::uuid
              else null
            end
          ) = p_zone_id
      )
    );

  v_total_cogs := greatest(v_total_cogs - v_total_returns_cogs, 0);

  if p_zone_id is null then
    select coalesce(sum(quantity * cost_at_time), 0)
    into v_total_wastage
    from public.stock_wastage
    where created_at >= p_start_date and created_at <= p_end_date;

    select coalesce(sum(amount), 0)
    into v_total_expenses
    from public.expenses
    where date >= p_start_date::date and date <= p_end_date::date;
  else
    v_total_wastage := 0;
    v_total_expenses := 0;
  end if;

  if to_regclass('public.delivery_costs') is not null then
    select coalesce(sum(dc.cost_amount), 0)
    into v_total_delivery_cost
    from public.delivery_costs dc
    where dc.occurred_at >= p_start_date
      and dc.occurred_at <= p_end_date
      and (
        p_zone_id is null or exists (
          select 1 from public.orders o
          where o.id = dc.order_id
            and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
            and coalesce(
              o.delivery_zone_id,
              case
                when nullif(o.data->>'deliveryZoneId','') is not null
                     and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  then (o.data->>'deliveryZoneId')::uuid
                else null
              end
            ) = p_zone_id
        )
      );
  else
    v_total_delivery_cost := 0;
  end if;

  with effective_orders as (
    select
      o.id,
      o.status,
      coalesce(nullif(o.data->>'orderSource', ''), '') as order_source,
      case
        when p_invoice_only
          then nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz
        else coalesce(
          nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
          nullif(o.data->>'paidAt', '')::timestamptz,
          nullif(o.data->>'deliveredAt', '')::timestamptz,
          o.created_at
        )
      end as date_by,
      coalesce(
        o.delivery_zone_id,
        case
          when nullif(o.data->>'deliveryZoneId','') is not null
               and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (o.data->>'deliveryZoneId')::uuid
          else null
        end
      ) as zone_effective
    from public.orders o
    where (p_zone_id is null or coalesce(
      o.delivery_zone_id,
      case
        when nullif(o.data->>'deliveryZoneId','') is not null
             and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (o.data->>'deliveryZoneId')::uuid
        else null
      end
    ) = p_zone_id)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  )
  select
    count(*) filter (where eo.status = 'delivered' and eo.order_source = 'delivery'),
    count(*) filter (where eo.status = 'delivered' and coalesce(eo.order_source, '') in ('', 'in_store', 'dine_in')),
    count(*) filter (where eo.status = 'delivered' and eo.order_source = 'online')
  into v_out_for_delivery, v_in_store, v_online
  from effective_orders eo
  where eo.date_by >= p_start_date
    and eo.date_by <= p_end_date;

  v_result := json_build_object(
    'totalCollected', v_total_collected,
    'totalTax', v_total_tax,
    'totalDeliveryFee', v_total_delivery,
    'totalDiscounts', v_total_discounts,
    'grossSubtotal', v_gross_subtotal,
    'totalOrders', v_total_orders,
    'cancelledOrders', v_cancelled_orders,
    'deliveredOrders', v_delivered_orders,
    'totalReturns', v_total_returns,
    'totalCogs', v_total_cogs,
    'totalReturnsCogs', v_total_returns_cogs,
    'totalWastage', v_total_wastage,
    'totalExpenses', v_total_expenses,
    'totalDeliveryCost', v_total_delivery_cost,
    'outForDelivery', v_out_for_delivery,
    'inStore', v_in_store,
    'online', v_online,
    'taxRefunds', v_tax_refunds,
    'netSales', greatest(v_total_collected - v_total_tax - v_total_delivery + v_total_discounts - v_total_returns, 0),
    'grossProfit', greatest(
      v_total_collected - v_total_tax - v_total_delivery + v_total_discounts - v_total_returns - v_total_cogs,
      0
    ),
    'netProfit', greatest(
      v_total_collected - v_total_tax - v_total_delivery + v_total_discounts - v_total_returns
      - v_total_cogs - v_total_wastage - v_total_expenses - v_total_delivery_cost,
      0
    )
  );

  return v_result;
end;
$$;

revoke all on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from public;
grant execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) to authenticated;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
