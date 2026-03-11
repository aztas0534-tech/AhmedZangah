set app.allow_ledger_ddl = '1';

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'price_quotations' and column_name = 'converted_to_order_id'
  ) then
    alter table public.price_quotations add column converted_to_order_id text;
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'price_quotations' and column_name = 'converted_at'
  ) then
    alter table public.price_quotations add column converted_at timestamptz;
  end if;
end $$;

create index if not exists idx_price_quotations_converted_to_order_id
  on public.price_quotations(converted_to_order_id);

create index if not exists idx_price_quotations_converted_at
  on public.price_quotations(converted_at desc);

notify pgrst, 'reload schema';
