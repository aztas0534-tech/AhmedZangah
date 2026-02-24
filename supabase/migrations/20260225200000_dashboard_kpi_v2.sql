create or replace function public.get_dashboard_kpi_v2(
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
  v_sales jsonb;
  v_inventory_value numeric := 0;
  v_po_in_transit integer := 0;
  v_po_statuses jsonb := '{}'::jsonb;
  v_order_statuses jsonb := '{}'::jsonb;
  v_ar numeric := 0;
  v_ap numeric := 0;
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;

  v_sales := public.get_sales_report_summary(p_start_date, p_end_date, p_zone_id, p_invoice_only);

  begin
    v_inventory_value := coalesce(public.get_inventory_valuation(p_warehouse_id), 0);
  exception when others then
    v_inventory_value := 0;
  end;

  select
    coalesce(count(*) filter (where po.status in ('shipped','processing','ordered')), 0),
    coalesce(jsonb_object_agg(po.status, po.cnt) filter (where po.status is not null), '{}'::jsonb)
  into v_po_in_transit, v_po_statuses
  from (
    select po.status::text as status, count(*)::integer as cnt
    from public.purchase_orders po
    where (p_warehouse_id is null or po.destination_warehouse_id = p_warehouse_id)
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

  return jsonb_build_object(
    'sales', coalesce(v_sales, '{}'::jsonb),
    'inventoryValue', coalesce(v_inventory_value, 0),
    'poInTransit', coalesce(v_po_in_transit, 0),
    'poStatusCounts', coalesce(v_po_statuses, '{}'::jsonb),
    'orderStatusCounts', coalesce(v_order_statuses, '{}'::jsonb),
    'arTotal', coalesce(v_ar, 0),
    'apTotal', coalesce(v_ap, 0)
  );
end;
$$;

revoke all on function public.get_dashboard_kpi_v2(timestamptz, timestamptz, uuid, boolean, uuid) from public;
revoke execute on function public.get_dashboard_kpi_v2(timestamptz, timestamptz, uuid, boolean, uuid) from anon;
grant execute on function public.get_dashboard_kpi_v2(timestamptz, timestamptz, uuid, boolean, uuid) to authenticated;

notify pgrst, 'reload schema';

