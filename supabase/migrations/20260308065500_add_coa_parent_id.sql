-- Add parent_id column to chart_of_accounts for hierarchical account relationships
-- This column is referenced by ManageOrdersScreen destination account queries
-- and by validation triggers in payment directory functions.

alter table public.chart_of_accounts
  add column if not exists parent_id uuid references public.chart_of_accounts(id);

create index if not exists idx_coa_parent_id on public.chart_of_accounts(parent_id);

-- Backfill parent_id based on code patterns:
-- Accounts with codes like '1020-001-YER' have parent '1020'
-- Accounts with codes like '1030-001-SAR' have parent '1030'
do $$
declare
  v_row record;
  v_parent_code text;
  v_parent_id uuid;
begin
  for v_row in
    select id, code
    from public.chart_of_accounts
    where parent_id is null
      and code is not null
      and code ~ '^(1020|1030)-'
  loop
    v_parent_code := split_part(v_row.code, '-', 1);
    select id into v_parent_id
    from public.chart_of_accounts
    where code = v_parent_code
    limit 1;
    if v_parent_id is not null then
      update public.chart_of_accounts
      set parent_id = v_parent_id
      where id = v_row.id;
    end if;
  end loop;

  -- Also handle dot-separated codes like '1020.01'
  for v_row in
    select id, code
    from public.chart_of_accounts
    where parent_id is null
      and code is not null
      and code ~ '^(1020|1030)\.'
  loop
    v_parent_code := split_part(v_row.code, '.', 1);
    select id into v_parent_id
    from public.chart_of_accounts
    where code = v_parent_code
    limit 1;
    if v_parent_id is not null then
      update public.chart_of_accounts
      set parent_id = v_parent_id
      where id = v_row.id;
    end if;
  end loop;

  -- Handle currency-prefixed codes like 'YER-1020-001'
  for v_row in
    select id, code
    from public.chart_of_accounts
    where parent_id is null
      and code is not null
      and upper(code) ~ '^(YER|SAR|USD)-(1020|1030)-'
  loop
    v_parent_code := split_part(v_row.code, '-', 2);
    select id into v_parent_id
    from public.chart_of_accounts
    where code = v_parent_code
    limit 1;
    if v_parent_id is not null then
      update public.chart_of_accounts
      set parent_id = v_parent_id
      where id = v_row.id;
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
