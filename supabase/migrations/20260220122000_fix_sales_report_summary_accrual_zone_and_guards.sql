drop function if exists public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean);

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
  v_total_sales_accrual numeric := 0;
  v_total_tax numeric := 0;
  v_total_delivery numeric := 0;
  v_total_discounts numeric := 0;
  v_gross_subtotal numeric := 0;

  v_total_returns numeric := 0;

  v_total_cogs numeric := 0;
  v_total_returns_cogs numeric := 0;

  v_total_wastage numeric := 0;
  v_total_expenses numeric := 0;
  v_total_delivery_cost numeric := 0;

  v_total_orders integer := 0;
  v_total_orders_accrual integer := 0;
  v_delivered_orders integer := 0;
  v_cancelled_orders integer := 0;
  v_out_for_delivery integer := 0;
  v_in_store integer := 0;
  v_online integer := 0;
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;

  if p_start_date is null or p_end_date is null then
    raise exception 'start_date and end_date are required';
  end if;

  with effective_orders as (
    select
      o.id,
      o.status,
      o.created_at,
      o.invoice_number,
      coalesce(nullif(o.data->>'paymentMethod', ''), '') as payment_method,
      coalesce(nullif(o.data->>'orderSource', ''), '') as order_source,
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
      coalesce(o.fx_rate, 1) as fx_rate,
      coalesce(
        o.base_total,
        coalesce(nullif((o.data->>'total')::numeric, null), 0) * coalesce(o.fx_rate, 1)
      ) as total,
      (coalesce(nullif((o.data->>'taxAmount')::numeric, null), 0) * coalesce(o.fx_rate, 1)) as tax_amount,
      (coalesce(nullif((o.data->>'deliveryFee')::numeric, null), 0) * coalesce(o.fx_rate, 1)) as delivery_fee,
      (coalesce(nullif((o.data->>'discountAmount')::numeric, null), 0) * coalesce(o.fx_rate, 1)) as discount_amount,
      (coalesce(nullif((o.data->>'subtotal')::numeric, null), 0) * coalesce(o.fx_rate, 1)) as subtotal,
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
    where (
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
  ),
  ranged_orders as (
    select *
    from effective_orders eo
    where eo.date_by >= p_start_date
      and eo.date_by <= p_end_date
      and (
        not p_invoice_only
        or nullif(trim(coalesce(eo.invoice_number,'')), '') is not null
      )
  )
  select
    coalesce(sum(eo.total) filter (where eo.paid_at is not null or (eo.status = 'delivered' and eo.payment_method <> 'cash')), 0),
    coalesce(sum(eo.total) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.tax_amount) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.delivery_fee) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.discount_amount) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    coalesce(sum(eo.subtotal) filter (where eo.status = 'delivered' or eo.paid_at is not null), 0),
    count(*) filter (where eo.paid_at is not null or (eo.status = 'delivered' and eo.payment_method <> 'cash'))::int,
    count(*) filter (where eo.status = 'delivered' or eo.paid_at is not null)::int,
    count(*) filter (where eo.status = 'delivered')::int,
    count(*) filter (where eo.status = 'cancelled')::int,
    count(*) filter (where eo.status = 'out_for_delivery')::int,
    count(*) filter (where eo.status = 'delivered' and eo.order_source = 'in_store')::int,
    count(*) filter (where eo.status = 'delivered' and eo.order_source <> 'in_store')::int
  into
    v_total_collected,
    v_total_sales_accrual,
    v_total_tax,
    v_total_delivery,
    v_total_discounts,
    v_gross_subtotal,
    v_total_orders,
    v_total_orders_accrual,
    v_delivered_orders,
    v_cancelled_orders,
    v_out_for_delivery,
    v_in_store,
    v_online
  from ranged_orders eo;

  begin
    if to_regclass('public.sales_returns') is not null then
      select
        coalesce(sum(sr.total_refund_amount * coalesce(o.fx_rate, 1)), 0)
      into v_total_returns
      from public.sales_returns sr
      join public.orders o on o.id = sr.order_id
      where sr.status = 'completed'
        and sr.return_date >= p_start_date
        and sr.return_date <= p_end_date
        and (
          not p_invoice_only
          or nullif(trim(coalesce(o.invoice_number,'')), '') is not null
        )
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
        );
    else
      v_total_returns := 0;
    end if;
  exception when others then
    v_total_returns := 0;
  end;

  begin
    if to_regclass('public.order_item_cogs') is not null then
      with eligible_orders as (
        select eo.id
        from (
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
              end as date_by,
              o.invoice_number,
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
            where (
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
          )
          select *
          from effective_orders eo
          where eo.date_by >= p_start_date
            and eo.date_by <= p_end_date
            and (
              not p_invoice_only
              or nullif(trim(coalesce(eo.invoice_number,'')), '') is not null
            )
        ) eo
        where eo.status = 'delivered' or eo.paid_at is not null
      )
      select coalesce(sum(oic.total_cost), 0)
      into v_total_cogs
      from public.order_item_cogs oic
      join eligible_orders eo on eo.id = oic.order_id;
    else
      v_total_cogs := 0;
    end if;
  exception when others then
    v_total_cogs := 0;
  end;

  begin
    if coalesce(v_total_cogs, 0) <= 0 and to_regclass('public.inventory_movements') is not null and to_regclass('public.batches') is not null then
      with eligible_orders as (
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
            end as date_by,
            o.invoice_number,
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
          where (
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
        )
        select eo.id
        from effective_orders eo
        where eo.date_by >= p_start_date
          and eo.date_by <= p_end_date
          and (
            not p_invoice_only
            or nullif(trim(coalesce(eo.invoice_number,'')), '') is not null
          )
          and (eo.status = 'delivered' or eo.paid_at is not null)
      )
      select
        coalesce(sum(coalesce(nullif(im.total_cost, 0), im.quantity * coalesce(nullif(b.unit_cost, 0), 0))), 0)
      into v_total_cogs
      from public.inventory_movements im
      join public.batches b on b.id = im.batch_id
      join eligible_orders eo on eo.id::text = im.reference_id
      where im.reference_table = 'orders'
        and im.movement_type = 'sale_out'
        and im.batch_id is not null
        and im.occurred_at >= p_start_date
        and im.occurred_at <= p_end_date;
    end if;
  exception when others then
    v_total_cogs := coalesce(v_total_cogs, 0);
  end;

  begin
    if to_regclass('public.inventory_movements') is not null and to_regclass('public.batches') is not null and to_regclass('public.sales_returns') is not null then
      with eligible_orders as (
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
            end as date_by,
            o.invoice_number,
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
          where (
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
        )
        select eo.id
        from effective_orders eo
        where eo.date_by >= p_start_date
          and eo.date_by <= p_end_date
          and (
            not p_invoice_only
            or nullif(trim(coalesce(eo.invoice_number,'')), '') is not null
          )
          and (eo.status = 'delivered' or eo.paid_at is not null)
      )
      select coalesce(sum(coalesce(nullif(im.total_cost, 0), im.quantity * coalesce(nullif(b.unit_cost, 0), 0))), 0)
      into v_total_returns_cogs
      from public.inventory_movements im
      join public.batches b on b.id = im.batch_id
      join public.sales_returns sr on sr.id::text = im.reference_id
      join eligible_orders eo on eo.id = sr.order_id
      where im.reference_table = 'sales_returns'
        and im.movement_type = 'return_in'
        and im.batch_id is not null
        and sr.status = 'completed'
        and im.occurred_at >= p_start_date
        and im.occurred_at <= p_end_date;
    else
      v_total_returns_cogs := 0;
    end if;
  exception when others then
    v_total_returns_cogs := 0;
  end;

  begin
    if to_regclass('public.wastage_records') is not null then
      select coalesce(sum(w.cost_amount), 0)
      into v_total_wastage
      from public.wastage_records w
      where w.status = 'approved'
        and w.created_at >= p_start_date
        and w.created_at <= p_end_date
        and (p_zone_id is null or w.zone_id = p_zone_id);
    else
      v_total_wastage := 0;
    end if;
  exception when others then
    v_total_wastage := 0;
  end;

  begin
    if to_regclass('public.expenses') is not null then
      select coalesce(sum(e.amount), 0)
      into v_total_expenses
      from public.expenses e
      where e.status = 'approved'
        and e.created_at >= p_start_date
        and e.created_at <= p_end_date
        and (p_zone_id is null or e.zone_id = p_zone_id);
    else
      v_total_expenses := 0;
    end if;
  exception when others then
    v_total_expenses := 0;
  end;

  begin
    if to_regclass('public.delivery_costs') is not null then
      select coalesce(sum(dc.cost_amount), 0)
      into v_total_delivery_cost
      from public.delivery_costs dc
      where dc.created_at >= p_start_date
        and dc.created_at <= p_end_date
        and (p_zone_id is null or dc.zone_id = p_zone_id);
    else
      v_total_delivery_cost := 0;
    end if;
  exception when others then
    v_total_delivery_cost := 0;
  end;

  v_result := jsonb_build_object(
    'total_collected', public._money_round(v_total_collected),
    'total_sales_accrual', public._money_round(v_total_sales_accrual),
    'gross_subtotal', public._money_round(v_gross_subtotal),
    'returns', public._money_round(v_total_returns),
    'discounts', public._money_round(v_total_discounts),
    'tax', public._money_round(v_total_tax),
    'delivery_fees', public._money_round(v_total_delivery),
    'delivery_cost', public._money_round(v_total_delivery_cost),
    'cogs', public._money_round(greatest(coalesce(v_total_cogs, 0) - coalesce(v_total_returns_cogs, 0), 0)),
    'wastage', public._money_round(v_total_wastage),
    'expenses', public._money_round(v_total_expenses),
    'total_orders', v_total_orders,
    'total_orders_accrual', v_total_orders_accrual,
    'delivered_orders', v_delivered_orders,
    'cancelled_orders', v_cancelled_orders,
    'out_for_delivery_count', v_out_for_delivery,
    'in_store_count', v_in_store,
    'online_count', v_online,
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
