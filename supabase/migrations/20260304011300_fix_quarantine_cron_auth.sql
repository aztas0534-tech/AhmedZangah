-- ============================================================================
-- Hotfix: quarantine_expired_batches cron compatibility
-- The original function called recompute_stock_for_item which requires
-- _require_staff() auth context. The cron runs without auth, so we replace
-- with direct stock update logic.
-- ============================================================================

create or replace function public.quarantine_expired_batches()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int := 0;
  v_batch record;
  v_is_food boolean;
begin
  for v_batch in
    select b.id, b.item_id, b.warehouse_id, b.expiry_date,
           greatest(
             coalesce(b.quantity_received,0)
             - coalesce(b.quantity_consumed,0)
             - coalesce(b.quantity_transferred,0),
             0
           ) as remaining_qty,
           coalesce(b.unit_cost, 0) as unit_cost
    from public.batches b
    where b.expiry_date is not null
      and b.expiry_date < current_date
      and coalesce(b.status, 'active') = 'active'
      and coalesce(b.qc_status, 'released') <> 'quarantined'
      and greatest(
            coalesce(b.quantity_received,0)
            - coalesce(b.quantity_consumed,0)
            - coalesce(b.quantity_transferred,0),
            0
          ) > 0
  loop
    -- Mark batch as quarantined
    update public.batches
    set qc_status = 'quarantined',
        data = coalesce(data, '{}'::jsonb) || jsonb_build_object(
          'quarantinedAt', now()::text,
          'quarantineReason', 'expired',
          'daysExpired', (current_date - v_batch.expiry_date)::int
        ),
        updated_at = now()
    where id = v_batch.id;

    -- Direct stock recompute (no _require_staff needed for cron context)
    if v_batch.warehouse_id is not null then
      select (coalesce(mi.category,'') = 'food')
      into v_is_food
      from public.menu_items mi
      where mi.id::text = v_batch.item_id::text;

      update public.stock_management sm
      set available_quantity = coalesce((
            select sum(
              greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
            )
            from public.batches b
            where b.item_id::text = v_batch.item_id::text
              and b.warehouse_id = v_batch.warehouse_id
              and coalesce(b.status,'active') = 'active'
              and coalesce(b.qc_status,'') = 'released'
              and (
                not coalesce(v_is_food, false)
                or (b.expiry_date is not null and b.expiry_date >= current_date)
              )
          ), 0),
          qc_hold_quantity = coalesce((
            select sum(
              greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)
            )
            from public.batches b
            where b.item_id::text = v_batch.item_id::text
              and b.warehouse_id = v_batch.warehouse_id
              and coalesce(b.status,'active') = 'active'
              and coalesce(b.qc_status,'') <> 'released'
              and (
                not coalesce(v_is_food, false)
                or (b.expiry_date is not null and b.expiry_date >= current_date)
              )
          ), 0),
          last_updated = now(),
          updated_at = now()
      where sm.item_id::text = v_batch.item_id::text
        and sm.warehouse_id = v_batch.warehouse_id;
    end if;

    v_count := v_count + 1;
  end loop;

  return json_build_object('quarantined_batches', v_count, 'run_at', now()::text);
end;
$$;

revoke all on function public.quarantine_expired_batches() from public;
grant execute on function public.quarantine_expired_batches() to authenticated;
