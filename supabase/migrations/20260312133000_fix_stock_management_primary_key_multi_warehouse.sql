do $$
begin
  if exists (
    select 1
    from information_schema.table_constraints
    where table_schema = 'public'
      and table_name = 'stock_management'
      and constraint_name = 'stock_management_pkey'
      and constraint_type = 'PRIMARY KEY'
  ) then
    alter table public.stock_management drop constraint stock_management_pkey;
  end if;
end $$;

create unique index if not exists idx_stock_item_warehouse
  on public.stock_management(item_id, warehouse_id);

do $$
begin
  if not exists (
    select 1
    from information_schema.table_constraints
    where table_schema = 'public'
      and table_name = 'stock_management'
      and constraint_name = 'stock_management_pkey'
      and constraint_type = 'PRIMARY KEY'
  ) then
    alter table public.stock_management
      add constraint stock_management_pkey primary key (item_id, warehouse_id);
  end if;
end $$;

notify pgrst, 'reload schema';
