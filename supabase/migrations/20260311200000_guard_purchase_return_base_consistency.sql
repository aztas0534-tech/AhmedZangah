set app.allow_ledger_ddl = '1';

create or replace function public.validate_purchase_return_base_consistency(p_return_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
begin
  if p_return_id is null then
    return;
  end if;

  for v_row in
    with exp as (
      select
        pri.item_id::text as item_id,
        coalesce(sum(coalesce(pri.quantity, 0)), 0) as expected_qty
      from public.purchase_return_items pri
      where pri.return_id = p_return_id
      group by pri.item_id::text
    ),
    got as (
      select
        im.item_id::text as item_id,
        coalesce(sum(coalesce(im.quantity, 0)), 0) as actual_qty
      from public.inventory_movements im
      where im.movement_type = 'return_out'
        and im.reference_table = 'purchase_returns'
        and im.reference_id::text = p_return_id::text
      group by im.item_id::text
    )
    select
      e.item_id,
      e.expected_qty,
      coalesce(g.actual_qty, 0) as actual_qty
    from exp e
    left join got g on g.item_id = e.item_id
    where abs(e.expected_qty - coalesce(g.actual_qty, 0)) > 0.0001
  loop
    raise exception 'PURCHASE_RETURN_BASE_QTY_MISMATCH return_id=% item_id=% expected=% actual=%',
      p_return_id, v_row.item_id, v_row.expected_qty, v_row.actual_qty;
  end loop;
end;
$$;

create or replace function public.trg_validate_purchase_return_consistency_from_returns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.validate_purchase_return_base_consistency(new.id);
  return new;
end;
$$;

create or replace function public.trg_validate_purchase_return_consistency_from_items()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_return_id uuid;
begin
  v_return_id := coalesce(new.return_id, old.return_id);
  perform public.validate_purchase_return_base_consistency(v_return_id);
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.trg_validate_purchase_return_consistency_from_movements()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_return_id uuid;
  v_ref text;
begin
  if tg_op in ('INSERT', 'UPDATE') then
    if coalesce(new.movement_type, '') = 'return_out' and coalesce(new.reference_table, '') = 'purchase_returns' then
      v_ref := nullif(new.reference_id::text, '');
      if v_ref is not null and v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
        v_return_id := v_ref::uuid;
      end if;
    end if;
  end if;

  if v_return_id is null and tg_op in ('UPDATE', 'DELETE') then
    if coalesce(old.movement_type, '') = 'return_out' and coalesce(old.reference_table, '') = 'purchase_returns' then
      v_ref := nullif(old.reference_id::text, '');
      if v_ref is not null and v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
        v_return_id := v_ref::uuid;
      end if;
    end if;
  end if;

  if v_return_id is not null then
    perform public.validate_purchase_return_base_consistency(v_return_id);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_purchase_return_consistency_from_returns on public.purchase_returns;
create constraint trigger trg_validate_purchase_return_consistency_from_returns
after insert or update
on public.purchase_returns
deferrable initially deferred
for each row
execute function public.trg_validate_purchase_return_consistency_from_returns();

drop trigger if exists trg_validate_purchase_return_consistency_from_items on public.purchase_return_items;
create constraint trigger trg_validate_purchase_return_consistency_from_items
after insert or update or delete
on public.purchase_return_items
deferrable initially deferred
for each row
execute function public.trg_validate_purchase_return_consistency_from_items();

drop trigger if exists trg_validate_purchase_return_consistency_from_movements on public.inventory_movements;
create constraint trigger trg_validate_purchase_return_consistency_from_movements
after insert or update or delete
on public.inventory_movements
deferrable initially deferred
for each row
execute function public.trg_validate_purchase_return_consistency_from_movements();

revoke all on function public.validate_purchase_return_base_consistency(uuid) from public;
grant execute on function public.validate_purchase_return_base_consistency(uuid) to authenticated;

notify pgrst, 'reload schema';
