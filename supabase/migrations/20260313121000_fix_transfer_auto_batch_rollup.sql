create or replace function public.trg_transfer_movement_ensure_batch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_id uuid;
  v_ref_prefix text;
begin
  if new.batch_id is not null then
    return new;
  end if;

  if new.movement_type not in ('transfer_out', 'transfer_in') then
    return new;
  end if;

  v_ref_prefix := substring(coalesce(new.reference_id, new.id::text) from 1 for 8);

  if new.movement_type = 'transfer_in' then
    select b.id
    into v_batch_id
    from public.batches b
    where b.item_id::text = new.item_id::text
      and b.warehouse_id = new.warehouse_id
      and (
        (coalesce(b.data, '{}'::jsonb)->>'autoCreatedForTransfer')::boolean is true
        and coalesce(b.data->>'referenceTable', '') = coalesce(new.reference_table, '')
        and coalesce(b.data->>'referenceId', '') = coalesce(new.reference_id, '')
      )
    order by b.created_at desc
    limit 1;

    if v_batch_id is null then
      select b.id
      into v_batch_id
      from public.batches b
      where b.item_id::text = new.item_id::text
        and b.warehouse_id = new.warehouse_id
        and coalesce(b.batch_code, '') = concat('TRF-AUTO-', v_ref_prefix)
      order by b.created_at desc
      limit 1;
    end if;
  else
    select b.id
    into v_batch_id
    from public.batches b
    where b.item_id::text = new.item_id::text
      and b.warehouse_id = new.warehouse_id
      and coalesce(b.qc_status, 'released') = 'released'
      and not exists (
        select 1
        from public.batch_recalls br
        where br.batch_id = b.id
          and br.status = 'active'
      )
    order by b.created_at asc
    limit 1;
  end if;

  if v_batch_id is null then
    v_batch_id := gen_random_uuid();
    insert into public.batches(
      id,
      item_id,
      warehouse_id,
      batch_code,
      quantity_received,
      quantity_consumed,
      unit_cost,
      cost_per_unit,
      qc_status,
      data
    )
    values (
      v_batch_id,
      new.item_id::text,
      new.warehouse_id,
      concat('TRF-AUTO-', v_ref_prefix),
      case when new.movement_type = 'transfer_in' then greatest(coalesce(new.quantity, 0), 0) else 0 end,
      0,
      coalesce(new.unit_cost, 0),
      coalesce(new.unit_cost, 0),
      'released',
      jsonb_build_object(
        'autoCreatedForTransfer', true,
        'referenceTable', new.reference_table,
        'referenceId', new.reference_id,
        'movementType', new.movement_type
      )
    );
  elsif new.movement_type = 'transfer_in' then
    update public.batches b
    set
      quantity_received = coalesce(b.quantity_received, 0) + greatest(coalesce(new.quantity, 0), 0),
      unit_cost = case
        when coalesce(b.unit_cost, 0) = 0 and coalesce(new.unit_cost, 0) > 0 then new.unit_cost
        else b.unit_cost
      end,
      cost_per_unit = case
        when coalesce(b.cost_per_unit, 0) = 0 and coalesce(new.unit_cost, 0) > 0 then new.unit_cost
        else b.cost_per_unit
      end,
      updated_at = now()
    where b.id = v_batch_id;
  end if;

  new.batch_id := v_batch_id;
  return new;
end;
$$;

drop trigger if exists a_trg_transfer_movement_ensure_batch on public.inventory_movements;
create trigger a_trg_transfer_movement_ensure_batch
before insert on public.inventory_movements
for each row execute function public.trg_transfer_movement_ensure_batch();

notify pgrst, 'reload schema';
