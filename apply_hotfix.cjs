const fs = require('fs');
const { createClient } = require('@supabase/supabase-js');
const s = createClient(
  'https://pmhivhtaoydfolseelyc.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBtaGl2aHRhb3lkZm9sc2VlbHljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAyMjkyNzYsImV4cCI6MjA4NTgwNTI3Nn0.S4y-P0oA26xBCkzyYKWRreetcDd1Qo6Pbd80b7hltec'
);

(async () => {
  // Step 1: Re-apply the get_sales_report_summary function — the LATEST version 
  // from migration 20260226150000 which has proper to_regclass guards
  // We need to use DO block + EXECUTE since exec_debug_sql uses `execute q into result`
  
  const createFn = `
do $outer$
begin
  execute $ddl$
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
    as $fn$
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
      v_total_returns_total numeric := 0;
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

      -- Main orders calculation
      with effective_orders as (
        select
          o.id,
          o.status,
          o.created_at,
          coalesce(nullif(o.data->>$$paymentMethod$$, $$$$), $$$$) as payment_method,
          nullif(o.data->>$$paidAt$$, $$$$)::timestamptz as paid_at,
          case
            when p_invoice_only
              then nullif(o.data->$$invoiceSnapshot$$->>$$issuedAt$$, $$$$)::timestamptz
            else coalesce(
              nullif(o.data->$$invoiceSnapshot$$->>$$issuedAt$$, $$$$)::timestamptz,
              nullif(o.data->>$$paidAt$$, $$$$)::timestamptz,
              nullif(o.data->>$$deliveredAt$$, $$$$)::timestamptz,
              o.created_at
            )
          end as date_by,
          coalesce(
            o.base_total,
            coalesce(nullif((o.data->>$$total$$)::numeric, null), 0)
          ) as total,
          (coalesce(nullif((o.data->>$$taxAmount$$)::numeric, null), coalesce(o.tax_amount, 0), 0)) as tax_amount,
          (coalesce(nullif((o.data->>$$deliveryFee$$)::numeric, null), 0)) as delivery_fee,
          (coalesce(nullif((o.data->>$$discountAmount$$)::numeric, null), 0)) as discount_amount,
          (coalesce(nullif((o.data->>$$subtotal$$)::numeric, null), 0)) as subtotal,
          coalesce(
            o.delivery_zone_id,
            case
              when nullif(o.data->>$$deliveryZoneId$$,$$$$) is not null
                   and (o.data->>$$deliveryZoneId$$) ~* $$^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$$$
                then (o.data->>$$deliveryZoneId$$)::uuid
              else null
            end
          ) as zone_effective
        from public.orders o
        where (p_zone_id is null or coalesce(
          o.delivery_zone_id,
          case
            when nullif(o.data->>$$deliveryZoneId$$,$$$$) is not null
                 and (o.data->>$$deliveryZoneId$$) ~* $$^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$$$
              then (o.data->>$$deliveryZoneId$$)::uuid
            else null
          end
        ) = p_zone_id)
          and nullif(trim(coalesce(o.data->>$$voidedAt$$,$$$$)), $$$$) is null
      )
      select
        coalesce(sum(eo.total) filter (where eo.paid_at is not null or (eo.status = $$delivered$$ and eo.payment_method <> $$cash$$)), 0),
        coalesce(sum(eo.total) filter (where eo.status = $$delivered$$ or eo.paid_at is not null), 0),
        coalesce(sum(eo.tax_amount) filter (where eo.status = $$delivered$$ or eo.paid_at is not null), 0),
        coalesce(sum(eo.delivery_fee) filter (where eo.status = $$delivered$$ or eo.paid_at is not null), 0),
        coalesce(sum(eo.discount_amount) filter (where eo.status = $$delivered$$ or eo.paid_at is not null), 0),
        coalesce(sum(eo.subtotal) filter (where eo.status = $$delivered$$ or eo.paid_at is not null), 0),
        count(*) filter (where eo.paid_at is not null or (eo.status = $$delivered$$ and eo.payment_method <> $$cash$$)),
        count(*) filter (where eo.status = $$delivered$$ or eo.paid_at is not null),
        count(*) filter (where eo.status = $$delivered$$)
      into
        v_total_collected, v_total_sales_accrual, v_total_tax, v_total_delivery,
        v_total_discounts, v_gross_subtotal, v_total_orders, v_total_orders_accrual, v_delivered_orders
      from effective_orders eo
      where (eo.status = $$delivered$$ or eo.paid_at is not null)
        and eo.date_by >= p_start_date and eo.date_by <= p_end_date;

      -- COGS
      v_total_cogs := coalesce(
        (select sum(oic.total_cost) from public.order_item_cogs oic
         join public.orders o on oic.order_id = o.id
         where o.status = $$delivered$$
           and o.created_at >= p_start_date and o.created_at <= p_end_date),
        0
      );

      -- Wastage (with guard)
      if to_regclass($$public.wastage_records$$) is not null then
        begin
          select coalesce(sum(w.cost_amount), 0)
          into v_total_wastage
          from public.wastage_records w
          where w.status = $$approved$$
            and w.created_at >= p_start_date and w.created_at <= p_end_date;
        exception when others then
          v_total_wastage := 0;
        end;
      elsif to_regclass($$public.stock_wastage$$) is not null then
        begin
          select coalesce(sum(sw.quantity * sw.cost_at_time), 0)
          into v_total_wastage
          from public.stock_wastage sw
          where sw.created_at >= p_start_date and sw.created_at <= p_end_date;
        exception when others then
          v_total_wastage := 0;
        end;
      else
        v_total_wastage := 0;
      end if;

      -- Expenses (with guard)
      if to_regclass($$public.expenses$$) is not null then
        begin
          select coalesce(sum(e.amount), 0)
          into v_total_expenses
          from public.expenses e
          where e.created_at >= p_start_date and e.created_at <= p_end_date;
        exception when others then
          v_total_expenses := 0;
        end;
      else
        v_total_expenses := 0;
      end if;

      -- Cancelled orders count
      v_cancelled_orders := coalesce(
        (select count(*) from public.orders o
         where o.status = $$cancelled$$
           and o.created_at >= p_start_date and o.created_at <= p_end_date),
        0
      );

      -- Source counts
      select 
        coalesce(count(*) filter (where o.status = $$out_for_delivery$$), 0),
        coalesce(count(*) filter (where o.status = $$delivered$$ and coalesce(o.data->>$$orderSource$$,$$$$) = $$in_store$$), 0),
        coalesce(count(*) filter (where o.status = $$delivered$$ and coalesce(o.data->>$$orderSource$$,$$$$) <> $$in_store$$), 0)
      into v_out_for_delivery, v_in_store, v_online
      from public.orders o
      where o.created_at >= p_start_date and o.created_at <= p_end_date;

      v_result := jsonb_build_object(
        $$total_collected$$, round(v_total_collected, 2),
        $$total_sales_accrual$$, round(v_total_sales_accrual, 2),
        $$gross_subtotal$$, round(v_gross_subtotal, 2),
        $$returns$$, round(v_total_returns, 2),
        $$returns_total$$, round(v_total_returns_total, 2),
        $$tax_refunds$$, round(v_tax_refunds, 2),
        $$discounts$$, round(v_total_discounts, 2),
        $$tax$$, round(v_total_tax, 2),
        $$delivery_fees$$, round(v_total_delivery, 2),
        $$delivery_cost$$, round(v_total_delivery_cost, 2),
        $$cogs$$, round(v_total_cogs, 2),
        $$returns_cogs$$, round(v_total_returns_cogs, 2),
        $$wastage$$, round(v_total_wastage, 2),
        $$expenses$$, round(v_total_expenses, 2),
        $$total_orders$$, v_total_orders,
        $$total_orders_accrual$$, v_total_orders_accrual,
        $$delivered_orders$$, v_delivered_orders,
        $$cancelled_orders$$, v_cancelled_orders,
        $$out_for_delivery_count$$, v_out_for_delivery,
        $$in_store_count$$, v_in_store,
        $$online_count$$, v_online
      );

      return v_result;
    end;
    $fn$
  $ddl$;

  execute $$revoke all on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from public$$;
  execute $$revoke execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) from anon$$;
  execute $$grant execute on function public.get_sales_report_summary(timestamptz, timestamptz, uuid, boolean) to authenticated$$;
  
  raise notice 'get_sales_report_summary updated OK';
end;
$outer$;
select to_jsonb('sales_summary_updated'::text)
  `;

  console.log('=== Re-applying get_sales_report_summary ===');
  const { data: d1, error: e1 } = await s.rpc('exec_debug_sql', { q: createFn });
  console.log(e1 ? 'ERROR: ' + JSON.stringify(e1) : 'OK: ' + d1);

  if (e1) {
    console.log('ABORTING - cannot continue');
    return;
  }

  // Schema reload
  await s.rpc('exec_debug_sql', { q: "notify pgrst, 'reload schema'; select to_jsonb(1)" });
  console.log('Schema reload sent');

  // Wait for PostgREST  
  console.log('Waiting 5s...');
  await new Promise(r => setTimeout(r, 5000));

  // Test the function  
  console.log('\n=== Testing get_sales_report_summary ===');
  const q = "select to_jsonb(public.get_sales_report_summary('2026-01-01'::timestamptz, '2026-03-31'::timestamptz, null, false))";
  const { data: d2, error: e2 } = await s.rpc('exec_debug_sql', { q });
  console.log(e2 ? 'ERROR: ' + JSON.stringify(e2) : 'Result: ' + JSON.stringify(d2).substring(0, 400));
})();
