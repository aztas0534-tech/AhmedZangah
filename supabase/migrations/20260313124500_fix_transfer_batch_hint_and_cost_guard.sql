create or replace function public.trg_transfer_movement_ensure_batch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_id uuid;
  v_source_batch_id uuid;
  v_ref_prefix text;
  v_shipping_total numeric;
  v_source_unit_cost numeric;
begin
  v_ref_prefix := substring(coalesce(new.reference_id, new.id::text) from 1 for 8);
  v_shipping_total := coalesce(nullif(new.data->>'shippingCostApplied', '')::numeric, 0);

  if new.batch_id is null and new.movement_type = 'transfer_out' then
    begin
      v_source_batch_id := nullif(new.data->>'batchId', '')::uuid;
    exception when others then
      v_source_batch_id := null;
    end;
    if v_source_batch_id is not null then
      if exists (
        select 1
        from public.batches b
        where b.id = v_source_batch_id
          and b.item_id::text = new.item_id::text
          and b.warehouse_id = new.warehouse_id
      ) then
        new.batch_id := v_source_batch_id;
      end if;
    end if;
  end if;

  if new.batch_id is not null then
    select b.unit_cost into v_source_unit_cost from public.batches b where b.id = new.batch_id;
    if coalesce(v_source_unit_cost, 0) > 0 and new.movement_type = 'transfer_out' then
      new.unit_cost := v_source_unit_cost;
      new.total_cost := coalesce(new.quantity, 0) * coalesce(new.unit_cost, 0);
    end if;
    return new;
  end if;

  if new.movement_type not in ('transfer_out', 'transfer_in') then
    return new;
  end if;

  if new.movement_type = 'transfer_in' then
    begin
      v_source_batch_id := nullif(new.data->>'batchId', '')::uuid;
    exception when others then
      v_source_batch_id := null;
    end;

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
      foreign_currency,
      foreign_unit_cost,
      fx_rate_at_receipt,
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
      case when v_source_batch_id is null then null else (select foreign_currency from public.batches where id = v_source_batch_id) end,
      case when v_source_batch_id is null then null else (select foreign_unit_cost from public.batches where id = v_source_batch_id) end,
      case when v_source_batch_id is null then null else (select fx_rate_at_receipt from public.batches where id = v_source_batch_id) end,
      jsonb_build_object(
        'autoCreatedForTransfer', true,
        'referenceTable', new.reference_table,
        'referenceId', new.reference_id,
        'movementType', new.movement_type,
        'sourceBatchId', case when v_source_batch_id is null then null else v_source_batch_id::text end
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
      foreign_currency = coalesce(
        b.foreign_currency,
        case when v_source_batch_id is null then null else (select foreign_currency from public.batches where id = v_source_batch_id) end
      ),
      foreign_unit_cost = coalesce(
        b.foreign_unit_cost,
        case when v_source_batch_id is null then null else (select foreign_unit_cost from public.batches where id = v_source_batch_id) end
      ),
      fx_rate_at_receipt = coalesce(
        b.fx_rate_at_receipt,
        case when v_source_batch_id is null then null else (select fx_rate_at_receipt from public.batches where id = v_source_batch_id) end
      ),
      updated_at = now()
    where b.id = v_batch_id;
  end if;

  new.batch_id := v_batch_id;

  if new.movement_type = 'transfer_in' and v_source_batch_id is not null then
    select b.unit_cost into v_source_unit_cost from public.batches b where b.id = v_source_batch_id;
    if coalesce(v_source_unit_cost, 0) > 0 then
      new.unit_cost := v_source_unit_cost + case when coalesce(new.quantity, 0) > 0 then (v_shipping_total / new.quantity) else 0 end;
      new.total_cost := coalesce(new.quantity, 0) * coalesce(new.unit_cost, 0);
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists a_trg_transfer_movement_ensure_batch on public.inventory_movements;
create trigger a_trg_transfer_movement_ensure_batch
before insert on public.inventory_movements
for each row execute function public.trg_transfer_movement_ensure_batch();

notify pgrst, 'reload schema';
