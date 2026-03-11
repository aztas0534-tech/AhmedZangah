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
  v_total_collected numeric := 0;
  v_total_sales_accrual numeric := 0;
  v_total_tax numeric := 0;
  v_total_delivery numeric := 0;
  v_total_discounts numeric := 0;
  v_gross_subtotal numeric := 0;
  v_total_orders integer := 0;
  v_total_orders_accrual integer := 0;
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
  v_result jsonb;
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
      ) as fx_rate_effective,
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
      (coalesce(nullif((o.data->>'taxAmount')::numeric, null), 0) * coalesce(public.order_fx_rate(
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
      ), 1)) as tax_amount,
      (coalesce(nullif((o.data->>'deliveryFee')::numeric, null), 0) * coalesce(public.order_fx_rate(
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
      ), 1)) as delivery_fee,
      (coalesce(nullif((o.data->>'discountAmount')::numeric, null), 0) * coalesce(public.order_fx_rate(
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
      ), 1)) as discount_amount,
      (coalesce(nullif((o.data->>'subtotal')::numeric, null), 0) * coalesce(public.order_fx_rate(
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
      ), 1)) as subtotal,
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
    coalesce(sum(eo.total) filter (where eo.paid_at is not null or (eo.status = 'delivered' and eo.payment_method <> 'cash')), 0),
    coalesce(sum(eo.total) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.tax_amount) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.delivery_fee) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.discount_amount) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.subtotal) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    count(*) filter (where eo.paid_at is not null or (eo.status = 'delivered' and eo.payment_method <> 'cash')),
    count(*) filter (where eo.status = 'delivered' or eo.paid_at is not null),
    count(*) filter (where eo.status = 'delivered')
  into
    v_total_collected,
    v_total_sales_accrual,
    v_total_tax,
    v_total_delivery,
    v_total_discounts,
    v_gross_subtotal,
    v_total_orders,
    v_total_orders_accrual,
    v_delivered_orders
  from effective_orders eo
  where (
      eo.status = 'delivered'
      or eo.paid_at is not null
  )
    and eo.date_by >= p_start_date
    and eo.date_by <= p_end_date;

  with effective_orders as (
    select
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

  with returns_base as (
    select
      (coalesce(sum(sr.total_refund_amount), 0) * public.order_fx_rate(
        coalesce(nullif(btrim(coalesce(o.currency, '')), ''), nullif(btrim(coalesce(o.data->>'currency', '')), ''), public.get_base_currency()),
        sr.return_date,
        o.fx_rate
      )) as total_refund_amount
    from public.sales_returns sr
    join public.orders o on o.id::text = sr.order_id::text
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
    group by o.id, o.data, o.currency, o.fx_rate, sr.return_date
  )
  select coalesce(sum(total_refund_amount), 0)
  into v_total_returns
  from returns_base;

  v_total_tax := greatest(v_total_tax - v_tax_refunds, 0);

  with effective_orders as (
    select
      o.id,
      o.status,
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
  where (eo.status = 'delivered' or eo.paid_at is not null)
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

  if to_regclass('public.wastage_records') is not null then
    begin
      select coalesce(sum(w.cost_amount), 0)
      into v_total_wastage
      from public.wastage_records w
      where w.status = 'approved'
        and w.created_at >= p_start_date
        and w.created_at <= p_end_date
        and (p_zone_id is null or w.zone_id = p_zone_id);
    exception when others then
      v_total_wastage := 0;
    end;
  elsif to_regclass('public.stock_wastage') is not null then
    begin
      select coalesce(sum(sw.quantity * sw.cost_at_time), 0)
      into v_total_wastage
      from public.stock_wastage sw
      where sw.created_at >= p_start_date
        and sw.created_at <= p_end_date;
    exception when others then
      v_total_wastage := 0;
    end;
  else
    v_total_wastage := 0;
  end if;

  if to_regclass('public.expenses') is not null then
    begin
      select coalesce(sum(e.amount), 0)
      into v_total_expenses
      from public.expenses e
      where e.status = 'approved'
        and e.created_at >= p_start_date
        and e.created_at <= p_end_date
        and (p_zone_id is null or e.zone_id = p_zone_id);
    exception when others then
      begin
        select coalesce(sum(e.amount), 0)
        into v_total_expenses
        from public.expenses e
        where e.created_at >= p_start_date
          and e.created_at <= p_end_date;
      exception when others then
        v_total_expenses := 0;
      end;
    end;
  else
    v_total_expenses := 0;
  end if;

  if to_regclass('public.delivery_costs') is not null then
    begin
      select coalesce(sum(dc.cost_amount), 0)
      into v_total_delivery_cost
      from public.delivery_costs dc
      where dc.created_at >= p_start_date
        and dc.created_at <= p_end_date
        and (p_zone_id is null or dc.zone_id = p_zone_id);
    exception when others then
      v_total_delivery_cost := 0;
    end;
  else
    v_total_delivery_cost := 0;
  end if;

  with effective_orders as (
    select
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
      nullif(trim(coalesce(o.data->>'orderSource','')), '') as os_raw,
      o.data
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
    coalesce(count(*) filter (where eo.status = 'out_for_delivery'), 0),
    coalesce(count(*) filter (where eo.status = 'delivered' and coalesce(eo.order_source,'') = 'in_store'), 0),
    coalesce(count(*) filter (where eo.status = 'delivered' and coalesce(eo.order_source,'') <> 'in_store'), 0)
  into v_out_for_delivery, v_in_store, v_online
  from effective_orders eo
  where eo.date_by >= p_start_date
    and eo.date_by <= p_end_date;

  v_result := jsonb_build_object(
    'total_collected', public._money_round(v_total_collected),
    'total_sales_accrual', public._money_round(v_total_sales_accrual),
    'gross_subtotal', public._money_round(v_gross_subtotal),
    'returns', public._money_round(v_total_returns),
    'discounts', public._money_round(v_total_discounts),
    'tax', public._money_round(v_total_tax),
    'delivery_fees', public._money_round(v_total_delivery),
    'delivery_cost', public._money_round(v_total_delivery_cost),
    'cogs', public._money_round(v_total_cogs),
    'wastage', public._money_round(v_total_wastage),
    'expenses', public._money_round(v_total_expenses),
    'total_orders', v_total_orders,
    'total_orders_accrual', v_total_orders_accrual,
    'delivered_orders', v_delivered_orders,
    'cancelled_orders', v_cancelled_orders,
    'out_for_delivery_count', v_out_for_delivery,
    'in_store_count', v_in_store,
    'online_count', v_online
  );

  return v_result;
end;
$$;

revoke all on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from public;
revoke execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from anon;
grant execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) to authenticated;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
