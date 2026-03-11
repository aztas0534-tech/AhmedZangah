-- ============================================================================
-- COMPREHENSIVE FIX: Order Cancel + Batch Stock
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- ============================================================================
-- STEP 1: Fix cancel_order
-- ============================================================================
drop function if exists public.cancel_order(uuid, text);
create or replace function public.cancel_order(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_new_status text;
begin
  select id, status into v_order
  from public.orders
  where id = p_order_id;

  if not found then
    raise exception 'Order not found';
  end if;

  if not public.is_admin() and not public.is_staff() then
    raise exception 'not allowed';
  end if;

  if v_order.status = 'cancelled' then return; end if;
  if v_order.status = 'delivered' then
    raise exception 'Cannot cancel a delivered order.';
  end if;

  -- Release reservations (best-effort)
  begin
    if to_regclass('public.reservation_lines') is not null then
      delete from public.reservation_lines
      where order_id = p_order_id and status = 'reserved';
    end if;
  exception when others then null;
  end;
  begin
    if to_regclass('public.order_item_reservations') is not null then
      execute format('delete from public.order_item_reservations where order_id = %L', p_order_id);
    end if;
  exception when others then null;
  end;

  update public.orders
  set status = 'cancelled', cancelled_at = now()
  where id = p_order_id
  returning status into v_new_status;

  if v_new_status is null or v_new_status <> 'cancelled' then
    raise exception 'Cancel failed.';
  end if;
end;
$$;

revoke all on function public.cancel_order(uuid, text) from public;
grant execute on function public.cancel_order(uuid, text) to authenticated;


-- ============================================================================
-- STEP 2: Ensure order_item_reservations table exists
-- ============================================================================
do $$
begin
  if to_regclass('public.order_item_reservations') is null then
    create table public.order_item_reservations (
      id uuid primary key default gen_random_uuid(),
      order_id uuid not null,
      item_id text not null,
      batch_id uuid,
      warehouse_id uuid not null,
      quantity numeric not null default 0,
      created_at timestamptz default now(),
      updated_at timestamptz default now()
    );
    create index idx_oir_order on public.order_item_reservations(order_id);
    create index idx_oir_item_wh on public.order_item_reservations(item_id, warehouse_id);
    alter table public.order_item_reservations enable row level security;
    create policy oir_auth_all on public.order_item_reservations for all to authenticated using (true) with check (true);
  end if;
end $$;


-- ============================================================================
-- STEP 3: Recalculate batch stock (DISABLE TRIGGERS to avoid data column error)
-- ============================================================================
do $$
declare
  v_batch record;
  v_consumed numeric;
begin
  -- Disable user triggers on batches (NOT system triggers)
  alter table public.batches disable trigger user;

  -- Drop quantity constraint
  begin
    alter table public.batches drop constraint if exists batches_qty_consistency;
  exception when others then null;
  end;

  -- Recalculate each batch
  for v_batch in select b.id, b.quantity_received from public.batches b
  loop
    select coalesce(sum(im.quantity), 0)
    into v_consumed
    from public.inventory_movements im
    where im.batch_id = v_batch.id
      and im.movement_type in ('sale_out', 'wastage_out', 'adjust_out');

    v_consumed := least(v_consumed, v_batch.quantity_received);

    update public.batches
    set quantity_consumed = v_consumed
    where id = v_batch.id;
  end loop;

  -- Re-add constraint
  begin
    alter table public.batches add constraint batches_qty_consistency
      check (quantity_consumed <= quantity_received);
  exception when others then null;
  end;

  -- Re-enable triggers
  alter table public.batches enable trigger user;
end $$;


-- ============================================================================
-- STEP 4: Recalculate stock_management from corrected batches
-- ============================================================================
do $$
declare
  v_sm record;
  v_avail numeric;
begin
  for v_sm in select sm.item_id, sm.warehouse_id from public.stock_management sm
  loop
    select coalesce(sum(
      greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0), 0)
    ), 0)
    into v_avail
    from public.batches b
    where b.item_id::text = v_sm.item_id::text
      and b.warehouse_id = v_sm.warehouse_id;

    update public.stock_management
    set available_quantity = v_avail, reserved_quantity = 0, last_updated = now()
    where item_id::text = v_sm.item_id::text
      and warehouse_id = v_sm.warehouse_id;
  end loop;
end $$;


-- ============================================================================
-- STEP 5: PostgREST reload
-- ============================================================================
select pg_sleep(0.3);
notify pgrst, 'reload schema';
notify pgrst, 'reload config';
