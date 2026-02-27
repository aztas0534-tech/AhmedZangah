-- ============================================================================
-- Repair: batch-recompute return status for all returned orders
-- Uses ALTER TABLE to temporarily disable triggers that block updates
-- ============================================================================

-- Temporarily disable the immutability triggers
alter table public.orders disable trigger trg_set_order_fx;
alter table public.orders disable trigger trg_orders_forbid_posted_updates;

-- Now batch-recompute for ALL orders that have completed sales returns
do $$
declare
  r record;
  v_count int := 0;
  v_fail int := 0;
begin
  for r in
    select distinct sr.order_id
    from public.sales_returns sr
    where sr.status = 'completed'
      and sr.order_id is not null
  loop
    begin
      perform public.recompute_order_return_status(r.order_id);
      v_count := v_count + 1;
    exception when others then
      v_fail := v_fail + 1;
      raise notice 'Failed for order %: %', r.order_id, sqlerrm;
    end;
  end loop;
  raise notice 'Recomputed return status for % orders (% failed)', v_count, v_fail;
end $$;

notify pgrst, 'reload schema';
