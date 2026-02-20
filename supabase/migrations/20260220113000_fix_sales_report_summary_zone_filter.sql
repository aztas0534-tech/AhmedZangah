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
      and (
        p_zone_id is null
        or coalesce(
          o.delivery_zone_id,
          case
            when nullif(o.data->>'deliveryZoneId','') is not null
                 and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
              then (o.data->>'deliveryZoneId')::uuid
            else null
          end
        ) = p_zone_id
      )
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
    select o.*
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (
        p_zone_id is null
        or coalesce(
          o.delivery_zone_id,
          case
            when nullif(o.data->>'deliveryZoneId','') is not null
                 and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
              then (o.data->>'deliveryZoneId')::uuid
            else null
          end
        ) = p_zone_id
      )
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
  )
  select
    coalesce(sum(coalesce(o.base_total, o.total)), 0),
    coalesce(sum(coalesce(nullif((o.data->>'taxAmount')::numeric, null), o.tax_amount, 0)), 0),
    coalesce(sum(coalesce(nullif((o.data->>'deliveryFee')::numeric, null), 0)), 0),
    coalesce(sum(coalesce(nullif((o.data->>'discountAmount')::numeric, null), o.discount, 0)), 0)
  into v_total_collected, v_total_tax, v_total_delivery, v_total_discounts
  from effective_orders o;

  with effective_orders as (
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (
        p_zone_id is null
        or coalesce(
          o.delivery_zone_id,
          case
            when nullif(o.data->>'deliveryZoneId','') is not null
                 and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
              then (o.data->>'deliveryZoneId')::uuid
            else null
          end
        ) = p_zone_id
      )
      and (not p_invoice_only or nullif(trim(coalesce(o.invoice_number,'')), '') is not null)
  )
  select coalesce(sum(sr.total_refund_amount), 0)
  into v_total_returns
  from public.sales_returns sr
  join effective_orders eo on eo.id = sr.order_id
  where sr.status = 'completed';

  with effective_orders as (
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and o.created_at between p_start_date and p_end_date
      and (
        p_zone_id is null
        or coalesce(
          o.delivery_zone_id,
          case
            when nullif(o.data->>'deliveryZoneId','') is not null
                 and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
              then (o.data->>'deliveryZoneId')::uuid
            else null
          end
        ) = p_zone_id
      )
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
        and (
          p_zone_id is null
          or coalesce(
            o.delivery_zone_id,
            case
              when nullif(o.data->>'deliveryZoneId','') is not null
                   and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                then (o.data->>'deliveryZoneId')::uuid
              else null
            end
          ) = p_zone_id
        )
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
      and (
        p_zone_id is null
        or coalesce(
          o.delivery_zone_id,
          case
            when nullif(o.data->>'deliveryZoneId','') is not null
                 and (o.data->>'deliveryZoneId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
              then (o.data->>'deliveryZoneId')::uuid
            else null
          end
        ) = p_zone_id
      )
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
