create or replace function public.get_dashboard_kpi_v4(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_zone_id uuid default null,
  p_invoice_only boolean default false,
  p_warehouse_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sales jsonb := '{}'::jsonb;
  v_inventory_value numeric := 0;
  v_po_in_transit integer := 0;
  v_po_statuses jsonb := '{}'::jsonb;
  v_order_statuses jsonb := '{}'::jsonb;
  v_ar numeric := 0;
  v_ap numeric := 0;
  v_purchases_total numeric := 0;
  v_purchase_returns_total numeric := 0;

  v_total_collected numeric := 0;
  v_total_sales_accrual numeric := 0;
  v_total_tax numeric := 0;
  v_total_delivery numeric := 0;
  v_total_discounts numeric := 0;
  v_gross_subtotal numeric := 0;
  v_total_orders integer := 0;
  v_total_orders_accrual integer := 0;
  v_delivered_orders integer := 0;
  v_cancelled_orders integer := 0;
  v_out_for_delivery integer := 0;
  v_in_store integer := 0;
  v_online integer := 0;

  v_total_returns numeric := 0;
  v_total_cogs numeric := 0;
  v_total_returns_cogs numeric := 0;
  v_total_wastage numeric := 0;
  v_total_expenses numeric := 0;
  v_total_delivery_cost numeric := 0;
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
      o.warehouse_id,
      o.data as data,
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
      and (p_warehouse_id is null or o.warehouse_id = p_warehouse_id)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
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
        and (p_warehouse_id is null or o.warehouse_id = p_warehouse_id)
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
    with eligible_orders as (
      select eo.id
      from ranged_orders eo
      where eo.status = 'delivered' or eo.paid_at is not null
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
              then coalesce(nullif((it->>'weight')::numeric, null), 0)
            else coalesce(nullif((it->>'quantity')::numeric, null), 0)
                 * coalesce(nullif((it->>'uomQtyInBase')::numeric, null), nullif((it->>'uom_qty_in_base')::numeric, null), 1)
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
  exception when others then
    v_total_cogs := 0;
  end;

  begin
    if to_regclass('public.inventory_movements') is not null and to_regclass('public.batches') is not null and to_regclass('public.sales_returns') is not null then
      with eligible_orders as (
        select eo.id
        from ranged_orders eo
        where eo.status = 'delivered' or eo.paid_at is not null
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
        and im.occurred_at <= p_end_date
        and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id);
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

  v_sales := jsonb_build_object(
    'total_collected', public._money_round(v_total_collected),
    'total_sales_accrual', public._money_round(v_total_sales_accrual),
    'gross_subtotal', public._money_round(v_gross_subtotal),
    'returns', public._money_round(v_total_returns),
    'returns_total', public._money_round(v_total_returns),
    'discounts', public._money_round(v_total_discounts),
    'tax', public._money_round(v_total_tax),
    'delivery_fees', public._money_round(v_total_delivery),
    'delivery_cost', public._money_round(v_total_delivery_cost),
    'cogs', public._money_round(greatest(coalesce(v_total_cogs, 0) - coalesce(v_total_returns_cogs, 0), 0)),
    'returns_cogs', public._money_round(v_total_returns_cogs),
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

  begin
    v_inventory_value := coalesce(public.get_inventory_valuation(p_warehouse_id), 0);
  exception when others then
    v_inventory_value := 0;
  end;

  select
    coalesce(count(*) filter (where po.status in ('draft','partial')), 0),
    coalesce(jsonb_object_agg(po.status, po.cnt) filter (where po.status is not null), '{}'::jsonb)
  into v_po_in_transit, v_po_statuses
  from (
    select po.status::text as status, count(*)::integer as cnt
    from public.purchase_orders po
    where (p_warehouse_id is null or po.warehouse_id = p_warehouse_id)
    group by po.status
  ) po;

  select coalesce(jsonb_object_agg(o.status, o.cnt) filter (where o.status is not null), '{}'::jsonb)
  into v_order_statuses
  from (
    select o.status::text as status, count(*)::integer as cnt
    from public.orders o
    where o.status in ('pending','preparing','out_for_delivery','scheduled')
      and (p_warehouse_id is null or o.warehouse_id = p_warehouse_id)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
    group by o.status
  ) o;

  begin
    select coalesce(sum(s.total_outstanding), 0) into v_ar
    from public.party_ar_aging_summary s;
  exception when others then
    v_ar := 0;
  end;

  begin
    select coalesce(sum(s.total_outstanding), 0) into v_ap
    from public.party_ap_aging_summary s;
  exception when others then
    v_ap := 0;
  end;

  begin
    if to_regclass('public.inventory_movements') is not null and to_regclass('public.purchase_receipts') is not null then
      select coalesce(sum(coalesce(im.total_cost, im.quantity * coalesce(im.unit_cost, 0))), 0)
      into v_purchases_total
      from public.inventory_movements im
      join public.purchase_receipts pr on pr.id = im.reference_id::uuid
      where im.reference_table = 'purchase_receipts'
        and im.movement_type = 'purchase_in'
        and im.occurred_at >= p_start_date
        and im.occurred_at <= p_end_date
        and (p_warehouse_id is null or pr.warehouse_id = p_warehouse_id);
    else
      v_purchases_total := 0;
    end if;
  exception when others then
    v_purchases_total := 0;
  end;

  begin
    if to_regclass('public.inventory_movements') is not null and to_regclass('public.purchase_returns') is not null and to_regclass('public.purchase_orders') is not null then
      select coalesce(sum(coalesce(im.total_cost, im.quantity * coalesce(im.unit_cost, 0))), 0)
      into v_purchase_returns_total
      from public.inventory_movements im
      join public.purchase_returns r on r.id = im.reference_id::uuid
      join public.purchase_orders po on po.id = r.purchase_order_id
      where im.reference_table = 'purchase_returns'
        and im.movement_type = 'return_out'
        and im.occurred_at >= p_start_date
        and im.occurred_at <= p_end_date
        and (p_warehouse_id is null or po.warehouse_id = p_warehouse_id);
    else
      v_purchase_returns_total := 0;
    end if;
  exception when others then
    v_purchase_returns_total := 0;
  end;

  return jsonb_build_object(
    'sales', coalesce(v_sales, '{}'::jsonb),
    'inventoryValue', coalesce(v_inventory_value, 0),
    'poInTransit', coalesce(v_po_in_transit, 0),
    'poStatusCounts', coalesce(v_po_statuses, '{}'::jsonb),
    'orderStatusCounts', coalesce(v_order_statuses, '{}'::jsonb),
    'arTotal', coalesce(v_ar, 0),
    'apTotal', coalesce(v_ap, 0),
    'purchasesTotal', public._money_round(coalesce(v_purchases_total, 0)),
    'purchaseReturnsTotal', public._money_round(coalesce(v_purchase_returns_total, 0)),
    'netPurchases', public._money_round(coalesce(v_purchases_total, 0) - coalesce(v_purchase_returns_total, 0))
  );
end;
$$;

revoke all on function public.get_dashboard_kpi_v4(timestamptz, timestamptz, uuid, boolean, uuid) from public;
revoke execute on function public.get_dashboard_kpi_v4(timestamptz, timestamptz, uuid, boolean, uuid) from anon;
grant execute on function public.get_dashboard_kpi_v4(timestamptz, timestamptz, uuid, boolean, uuid) to authenticated;

notify pgrst, 'reload schema';
