create or replace function public.sync_order_item_cogs_from_sale_out(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_order_id is null then
    return;
  end if;

  delete from public.order_item_cogs
  where order_id = p_order_id;

  insert into public.order_item_cogs(order_id, item_id, quantity, unit_cost, total_cost, created_at)
  select
    p_order_id,
    s.item_id_text,
    s.qty,
    case when s.qty > 0 then s.cost_sum / s.qty else 0 end as unit_cost,
    s.cost_sum,
    now()
  from (
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
      and im.reference_id = p_order_id::text
    group by im.item_id::text
  ) s
  where s.qty > 0 and s.cost_sum >= 0;
end;
$$;

create or replace function public.trg_sync_order_item_cogs_from_sale_out()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_new uuid;
  v_order_old uuid;
begin
  if tg_op in ('INSERT', 'UPDATE') then
    if coalesce(new.reference_table, '') = 'orders' and coalesce(new.movement_type, '') = 'sale_out' then
      if new.reference_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
        v_order_new := new.reference_id::uuid;
      end if;
    end if;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    if coalesce(old.reference_table, '') = 'orders' and coalesce(old.movement_type, '') = 'sale_out' then
      if old.reference_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
        v_order_old := old.reference_id::uuid;
      end if;
    end if;
  end if;

  if v_order_new is not null then
    perform public.sync_order_item_cogs_from_sale_out(v_order_new);
  end if;
  if v_order_old is not null and v_order_old is distinct from v_order_new then
    perform public.sync_order_item_cogs_from_sale_out(v_order_old);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_order_item_cogs_from_sale_out on public.inventory_movements;
create trigger trg_sync_order_item_cogs_from_sale_out
after insert or update or delete on public.inventory_movements
for each row
execute function public.trg_sync_order_item_cogs_from_sale_out();

revoke all on function public.sync_order_item_cogs_from_sale_out(uuid) from public;
revoke execute on function public.sync_order_item_cogs_from_sale_out(uuid) from anon;
grant execute on function public.sync_order_item_cogs_from_sale_out(uuid) to authenticated;

revoke all on function public.trg_sync_order_item_cogs_from_sale_out() from public;
revoke execute on function public.trg_sync_order_item_cogs_from_sale_out() from anon;
grant execute on function public.trg_sync_order_item_cogs_from_sale_out() to authenticated;

notify pgrst, 'reload schema';
