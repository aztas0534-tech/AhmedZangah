-- Fix UOM Inflation Detection: Account for Foreign Currency POs
-- Problem: When unit_cost_base is null, the function uses pi_unit_cost (in foreign currency)
-- and compares against total_cost (in base currency), creating false positives.
-- Solution: Multiply expected_unit_cost by po.fx_rate when PO currency != base currency.

set app.allow_ledger_ddl = '1';

create or replace function public.detect_purchase_in_uom_inflation(
  p_start timestamptz default null,
  p_end timestamptz default null,
  p_limit int default 200
)
returns table(
  movement_id uuid,
  occurred_at timestamptz,
  item_id text,
  reference_table text,
  reference_id text,
  quantity numeric,
  unit_cost numeric,
  total_cost numeric,
  expected_unit_cost numeric,
  expected_total_cost numeric,
  inflation_factor numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_staff('detect_purchase_in_uom_inflation');
  p_limit := greatest(1, least(coalesce(p_limit, 200), 2000));

  return query
  with mv as (
    select
      im.*,
      case when im.reference_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then im.reference_id::uuid else null end as ref_uuid,
      public.uuid_from_text(concat('uomfix:purchase_in:', im.id::text)) as fix_source_uuid
    from public.inventory_movements im
    where im.movement_type = 'purchase_in'
      and coalesce(im.reference_table,'') in ('purchase_orders','purchase_receipts')
      and (p_start is null or im.occurred_at >= p_start)
      and (p_end is null or im.occurred_at <= p_end)
    order by im.occurred_at desc, im.id desc
    limit p_limit
  ),
  joined as (
    select
      mv.id as movement_id,
      mv.occurred_at,
      mv.item_id,
      mv.reference_table,
      mv.reference_id,
      mv.quantity,
      mv.unit_cost,
      mv.total_cost,
      mv.warehouse_id,
      mv.data,
      mv.fix_source_uuid,
      pr.purchase_order_id as receipt_po_id,
      pi.qty_base as pi_qty_base,
      pi.quantity as pi_qty,
      pi.unit_cost_base as pi_unit_cost_base,
      pi.unit_cost as pi_unit_cost,
      pi.uom_id as pi_uom_id,
      mi.transport_cost as mi_transport_cost,
      mi.supply_tax_cost as mi_supply_tax_cost,
      pri.transport_cost as pri_transport_cost,
      pri.supply_tax_cost as pri_supply_tax_cost,
      -- NEW: Get PO currency info
      po.currency as po_currency,
      coalesce(po.fx_rate, 1) as po_fx_rate
    from mv
    left join public.purchase_receipts pr
      on mv.reference_table = 'purchase_receipts' and pr.id = mv.ref_uuid
    left join public.purchase_orders po
      on (
        (mv.reference_table = 'purchase_orders' and po.id = mv.ref_uuid)
        or (mv.reference_table = 'purchase_receipts' and pr.purchase_order_id is not null and po.id = pr.purchase_order_id)
      )
    left join public.purchase_items pi
      on pi.purchase_order_id = po.id
      and pi.item_id = mv.item_id
    left join public.menu_items mi on mi.id = mv.item_id
    left join public.purchase_receipt_items pri
      on mv.reference_table = 'purchase_receipts'
      and pri.receipt_id = mv.ref_uuid
      and pri.item_id = mv.item_id
  ),
  calc as (
    select
      j.*,
      greatest(
        coalesce(j.pi_qty_base, j.pi_qty, j.quantity, 0),
        0
      )::numeric as expected_qty_base,
      (
        coalesce(
          nullif(j.pi_unit_cost_base, 0),
          case
            when j.pi_uom_id is not null then public.item_unit_cost_to_base(j.item_id, coalesce(j.pi_unit_cost, 0), j.pi_uom_id)
            else null
          end,
          -- FIXED: Convert foreign currency unit_cost to base using FX rate
          case
            when j.po_currency is not null and j.po_currency <> 'SAR' and j.po_fx_rate > 0
            then coalesce(j.pi_unit_cost, 0) * j.po_fx_rate
            else coalesce(j.pi_unit_cost, 0)
          end,
          0
        )
        -- FIXED: Also convert transport/tax costs if they are in foreign currency
        + case
            when j.po_currency is not null and j.po_currency <> 'SAR' and j.po_fx_rate > 0
            then (coalesce(j.mi_transport_cost, 0) + coalesce(j.mi_supply_tax_cost, 0)
                + coalesce(j.pri_transport_cost, 0) + coalesce(j.pri_supply_tax_cost, 0)) * j.po_fx_rate
            else coalesce(j.mi_transport_cost, 0) + coalesce(j.mi_supply_tax_cost, 0)
                + coalesce(j.pri_transport_cost, 0) + coalesce(j.pri_supply_tax_cost, 0)
          end
      )::numeric as expected_unit_cost
    from joined j
  )
  select
    c.movement_id,
    c.occurred_at,
    c.item_id,
    c.reference_table,
    c.reference_id,
    c.quantity,
    c.unit_cost,
    c.total_cost,
    c.expected_unit_cost,
    (c.expected_qty_base * c.expected_unit_cost)::numeric as expected_total_cost,
    case
      when (c.expected_qty_base * c.expected_unit_cost) > 0 then (c.total_cost / (c.expected_qty_base * c.expected_unit_cost))::numeric
      else null
    end as inflation_factor
  from calc c
  where (c.expected_qty_base * c.expected_unit_cost) > 0
    and abs(coalesce(c.total_cost, 0) - (c.expected_qty_base * c.expected_unit_cost)) > 0.01
    and (coalesce(c.total_cost, 0) / (c.expected_qty_base * c.expected_unit_cost)) > 1.05
    and (coalesce(c.total_cost, 0) / (c.expected_qty_base * c.expected_unit_cost)) < 500
    -- Exclude already-fixed entries
    and not exists (
      select 1
      from public.journal_entries je
      where je.source_table = 'ledger_repairs'
        and je.source_id = c.fix_source_uuid::text
        and je.source_event = 'fix_purchase_in_uom'
    )
    -- NEW: Also exclude entries already fixed by our manual script
    and not exists (
      select 1
      from public.journal_entries je
      where je.source_table = 'inventory_movements'
        and je.source_id = c.movement_id::text
        and je.memo like '%(Fixed via Script)%'
    )
  order by c.occurred_at desc, c.movement_id desc;
end;
$$;

revoke all on function public.detect_purchase_in_uom_inflation(timestamptz, timestamptz, int) from public;
revoke execute on function public.detect_purchase_in_uom_inflation(timestamptz, timestamptz, int) from anon;
grant execute on function public.detect_purchase_in_uom_inflation(timestamptz, timestamptz, int) to authenticated, service_role;

notify pgrst, 'reload schema';
