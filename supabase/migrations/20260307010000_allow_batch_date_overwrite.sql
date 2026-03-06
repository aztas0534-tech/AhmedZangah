-- ============================================================================
-- Migration: Allow Batch Date Overwrite
-- Fixes "expiry_date is immutable" UI error when using RPC update_batch_dates
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- 1) Allow `update_batch_dates` authorized users to bypass immutability
create or replace function public.trg_batch_balances_expiry_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    if current_user not in ('postgres','supabase_admin') then
      raise exception 'not authenticated';
    end if;
  else
    perform public._require_staff('inventory_receive');
  end if;

  if old.expiry_date is distinct from new.expiry_date then
    -- BYPASS if user has specific permission to edit dates (used by update_batch_dates RPC)
    if public.has_admin_permission('update_batch_dates') then
      return new;
    end if;
    
    raise exception 'expiry_date is immutable';
  end if;
  return new;
end;
$$;

-- 2) Ensure batches sync correctly pushes non-null overwrites to batch_balances
create or replace function public.trg_sync_batch_balances_from_batches()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wh uuid;
  v_qty numeric;
begin
  if tg_op = 'DELETE' then
    delete from public.batch_balances bb
    where bb.item_id::text = old.item_id::text
      and bb.batch_id = old.id
      and bb.warehouse_id = old.warehouse_id;
    return old;
  end if;

  v_wh := coalesce(new.warehouse_id, public._resolve_default_admin_warehouse_id());
  if v_wh is null then
    raise exception 'warehouse_id is required';
  end if;

  if tg_op = 'UPDATE' then
    if old.warehouse_id is distinct from v_wh or old.item_id::text is distinct from new.item_id::text then
      delete from public.batch_balances bb
      where bb.item_id::text = old.item_id::text
        and bb.batch_id = old.id
        and bb.warehouse_id = old.warehouse_id;
    end if;
  end if;

  v_qty := greatest(
    coalesce(new.quantity_received, 0)
    - coalesce(new.quantity_consumed, 0)
    - coalesce(new.quantity_transferred, 0),
    0
  );

  insert into public.batch_balances(item_id, batch_id, warehouse_id, quantity, expiry_date, created_at, updated_at)
  values (new.item_id::text, new.id, v_wh, v_qty, new.expiry_date, now(), now())
  on conflict (item_id, batch_id, warehouse_id)
  do update set
    quantity = excluded.quantity,
    expiry_date = excluded.expiry_date, -- FORCE SYNC
    updated_at = now();

  return new;
end;
$$;

notify pgrst, 'reload schema';
