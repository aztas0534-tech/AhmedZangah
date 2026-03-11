set app.allow_ledger_ddl = '1';

create or replace function public.trg_guard_single_active_batch_per_receipt_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.receipt_id is null then
    return new;
  end if;

  if coalesce(new.status, 'active') <> 'active' then
    return new;
  end if;

  if exists (
    select 1
    from public.batches b
    where b.receipt_id = new.receipt_id
      and b.item_id::text = new.item_id::text
      and coalesce(b.status, 'active') = 'active'
      and (tg_op = 'INSERT' or b.id <> new.id)
    limit 1
  ) then
    raise exception 'DUPLICATE_ACTIVE_BATCH_FOR_RECEIPT_ITEM receipt % item %', new.receipt_id, new.item_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_single_active_batch_per_receipt_item on public.batches;
create trigger trg_guard_single_active_batch_per_receipt_item
before insert or update of receipt_id, item_id, status
on public.batches
for each row
execute function public.trg_guard_single_active_batch_per_receipt_item();

do $$
declare
  v_conflicts int := 0;
begin
  select count(*)
  into v_conflicts
  from (
    select b.receipt_id, b.item_id
    from public.batches b
    where b.receipt_id is not null
      and coalesce(b.status, 'active') = 'active'
    group by b.receipt_id, b.item_id
    having count(*) > 1
  ) x;

  if v_conflicts > 0 then
    raise warning 'ACTIVE duplicate receipt-item batches currently exist: % groups', v_conflicts;
  end if;
end $$;

notify pgrst, 'reload schema';
