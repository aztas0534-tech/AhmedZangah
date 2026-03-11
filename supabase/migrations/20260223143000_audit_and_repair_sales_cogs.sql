set app.allow_ledger_ddl = '1';

create or replace function public.audit_sales_cogs(
  p_start_date timestamptz default null,
  p_end_date timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamptz := p_start_date;
  v_end timestamptz := p_end_date;
  v_total_orders int := 0;
  v_missing_cogs int := 0;
  v_zero_cogs int := 0;
  v_missing_sale_out int := 0;
  v_sample_missing text[] := array[]::text[];
  v_sample_zero text[] := array[]::text[];
  v_sample_missing_sale text[] := array[]::text[];
begin
  if auth.role() <> 'service_role' then
    if not public.is_staff() then
      raise exception 'not allowed';
    end if;
  end if;

  if to_regclass('public.orders') is null then
    return jsonb_build_object('ok', false, 'error', 'orders table missing');
  end if;

  with target_orders as (
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and (v_start is null or o.created_at >= v_start)
      and (v_end is null or o.created_at <= v_end)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
  ),
  cogs_sum as (
    select oic.order_id, sum(coalesce(oic.total_cost, 0)) as total_cost
    from public.order_item_cogs oic
    join target_orders t on t.id = oic.order_id
    group by oic.order_id
  ),
  sale_sum as (
    select (im.reference_id)::uuid as order_id,
           sum(coalesce(nullif(im.total_cost, 0), im.quantity * coalesce(nullif(im.unit_cost, 0), 0), 0)) as movement_cost
    from public.inventory_movements im
    join target_orders t on t.id::text = im.reference_id
    where im.reference_table = 'orders'
      and im.movement_type = 'sale_out'
    group by (im.reference_id)::uuid
  ),
  joined as (
    select
      t.id as order_id,
      coalesce(cs.total_cost, null) as cogs_cost,
      coalesce(ss.movement_cost, null) as sale_cost
    from target_orders t
    left join cogs_sum cs on cs.order_id = t.id
    left join sale_sum ss on ss.order_id = t.id
  )
  select
    count(*)::int,
    count(*) filter (where cogs_cost is null)::int,
    count(*) filter (where cogs_cost is not null and coalesce(cogs_cost, 0) <= 0)::int,
    count(*) filter (where sale_cost is null)::int,
    coalesce((array_agg(order_id::text order by order_id) filter (where cogs_cost is null))[1:20], array[]::text[]),
    coalesce((array_agg(order_id::text order by order_id) filter (where cogs_cost is not null and coalesce(cogs_cost, 0) <= 0))[1:20], array[]::text[]),
    coalesce((array_agg(order_id::text order by order_id) filter (where sale_cost is null))[1:20], array[]::text[])
  into
    v_total_orders,
    v_missing_cogs,
    v_zero_cogs,
    v_missing_sale_out,
    v_sample_missing,
    v_sample_zero,
    v_sample_missing_sale
  from joined;

  return jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('start', v_start, 'end', v_end),
    'counts', jsonb_build_object(
      'deliveredOrders', v_total_orders,
      'ordersMissingCogs', v_missing_cogs,
      'ordersZeroCogs', v_zero_cogs,
      'ordersMissingSaleOutMovements', v_missing_sale_out
    ),
    'samples', jsonb_build_object(
      'missingCogs', to_jsonb(v_sample_missing),
      'zeroCogs', to_jsonb(v_sample_zero),
      'missingSaleOut', to_jsonb(v_sample_missing_sale)
    )
  );
end;
$$;

revoke all on function public.audit_sales_cogs(timestamptz, timestamptz) from public;
revoke execute on function public.audit_sales_cogs(timestamptz, timestamptz) from anon;
grant execute on function public.audit_sales_cogs(timestamptz, timestamptz) to authenticated;

create or replace function public.repair_sales_cogs(
  p_start_date timestamptz default null,
  p_end_date timestamptz default null,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamptz := p_start_date;
  v_end timestamptz := p_end_date;
  v_dry boolean := coalesce(p_dry_run, true);
  v_orders int := 0;
  v_fixed int := 0;
  v_failed int := 0;
  v_estimated int := 0;
  v_fixed_ids text[] := array[]::text[];
  v_failed_ids text[] := array[]::text[];
  r record;
  v_has_any boolean;
begin
  if auth.role() <> 'service_role' then
    if not public.is_admin() then
      raise exception 'not allowed';
    end if;
  end if;

  if to_regclass('public.orders') is null
     or to_regclass('public.order_item_cogs') is null
     or to_regclass('public.inventory_movements') is null
  then
    return jsonb_build_object('ok', false, 'error', 'required tables missing');
  end if;

  for r in
    select o.id
    from public.orders o
    where o.status = 'delivered'
      and (v_start is null or o.created_at >= v_start)
      and (v_end is null or o.created_at <= v_end)
      and nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
    order by o.created_at asc
  loop
    v_orders := v_orders + 1;
    begin
      with sale_lines as (
        select
          im.item_id::text as item_id_text,
          sum(coalesce(im.quantity, 0)) as qty,
          sum(
            coalesce(
              nullif(im.total_cost, 0),
              im.quantity * coalesce(nullif(b.unit_cost, 0), nullif(im.unit_cost, 0), 0),
              0
            )
          ) as cost_sum,
          bool_or(
            coalesce(
              nullif(im.total_cost, 0),
              im.quantity * coalesce(nullif(b.unit_cost, 0), nullif(im.unit_cost, 0), 0),
              0
            ) <= 0
          ) as any_zero_cost
        from public.inventory_movements im
        left join public.batches b on b.id = im.batch_id
        where im.reference_table = 'orders'
          and im.movement_type = 'sale_out'
          and im.reference_id = r.id::text
        group by im.item_id::text
      ),
      with_fallback as (
        select
          sl.item_id_text,
          sl.qty,
          case
            when sl.cost_sum > 0 then sl.cost_sum
            else sl.qty * coalesce(nullif(sm.avg_cost, 0), nullif(mi.cost_price, 0), 0)
          end as total_cost,
          case
            when sl.cost_sum > 0 and sl.qty > 0 then (sl.cost_sum / sl.qty)
            when sl.qty > 0 then coalesce(nullif(sm.avg_cost, 0), nullif(mi.cost_price, 0), 0)
            else 0
          end as unit_cost,
          (sl.cost_sum <= 0) as estimated
        from sale_lines sl
        left join public.stock_management sm on sm.item_id::text = sl.item_id_text
        left join public.menu_items mi on mi.id::text = sl.item_id_text
      )
      select exists (select 1 from sale_lines) into v_has_any;

      if not v_has_any then
        v_failed := v_failed + 1;
        v_failed_ids := array_append(v_failed_ids, r.id::text);
        continue;
      end if;

      if not v_dry then
        delete from public.order_item_cogs where order_id = r.id;

        insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
        select
          r.id,
          wf.item_id_text,
          wf.qty,
          wf.unit_cost,
          wf.total_cost,
          now()
        from with_fallback wf
        where wf.qty > 0 and wf.total_cost >= 0;
      end if;

      select count(*) > 0
      into v_has_any
      from (
        with sale_lines as (
          select
            im.item_id::text as item_id_text,
            sum(coalesce(im.quantity, 0)) as qty,
            sum(
              coalesce(
                nullif(im.total_cost, 0),
                im.quantity * coalesce(nullif(b.unit_cost, 0), nullif(im.unit_cost, 0), 0),
                0
              )
            ) as cost_sum
          from public.inventory_movements im
          left join public.batches b on b.id = im.batch_id
          where im.reference_table = 'orders'
            and im.movement_type = 'sale_out'
            and im.reference_id = r.id::text
          group by im.item_id::text
        )
        select 1
        from sale_lines sl
        left join public.stock_management sm on sm.item_id::text = sl.item_id_text
        left join public.menu_items mi on mi.id::text = sl.item_id_text
        where sl.qty > 0 and sl.cost_sum <= 0 and coalesce(nullif(sm.avg_cost, 0), nullif(mi.cost_price, 0), 0) > 0
        limit 1
      ) x;
      if v_has_any then
        v_estimated := v_estimated + 1;
      end if;

      v_fixed := v_fixed + 1;
      v_fixed_ids := array_append(v_fixed_ids, r.id::text);
    exception when others then
      v_failed := v_failed + 1;
      v_failed_ids := array_append(v_failed_ids, r.id::text);
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'dryRun', v_dry,
    'range', jsonb_build_object('start', v_start, 'end', v_end),
    'counts', jsonb_build_object(
      'ordersScanned', v_orders,
      'ordersRebuilt', v_fixed,
      'ordersFailed', v_failed,
      'ordersUsedEstimates', v_estimated
    ),
    'samples', jsonb_build_object(
      'rebuilt', to_jsonb(v_fixed_ids[1:25]),
      'failed', to_jsonb(v_failed_ids[1:25])
    )
  );
end;
$$;

revoke all on function public.repair_sales_cogs(timestamptz, timestamptz, boolean) from public;
revoke execute on function public.repair_sales_cogs(timestamptz, timestamptz, boolean) from anon;
grant execute on function public.repair_sales_cogs(timestamptz, timestamptz, boolean) to authenticated;

select pg_sleep(0.2);
notify pgrst, 'reload schema';

