set app.allow_ledger_ddl = '1';

do $$
declare
  v_min timestamptz;
  v_max timestamptz;
  r record;
  v_entry_id uuid;
  v_fix_source_uuid uuid;
  v_posted_total numeric;
  v_delta numeric;
  v_inventory uuid;
  v_cogs uuid;
  v_branch uuid;
  v_company uuid;
begin
  if to_regclass('public.inventory_movements') is null or to_regclass('public.batches') is null then
    return;
  end if;

  v_inventory := public.get_account_id_by_code('1410');
  v_cogs := public.get_account_id_by_code('5010');
  if v_inventory is null or v_cogs is null then
    raise exception 'required accounts not found (inventory 1410 / cogs 5010)';
  end if;

  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements disable trigger trg_inventory_movements_forbid_modify_posted;
  end if;

  create temp table if not exists tmp_cogs_fix_movements(movement_id uuid primary key) on commit drop;
  truncate table tmp_cogs_fix_movements;

  insert into tmp_cogs_fix_movements(movement_id)
  select im.id
  from public.inventory_movements im
  join public.batches b on b.id = im.batch_id
  where im.movement_type in ('sale_out','return_in')
    and im.batch_id is not null
    and coalesce(b.unit_cost, 0) > 0
    and abs(coalesce(im.total_cost, 0) - (coalesce(im.quantity, 0) * coalesce(b.unit_cost, 0)))
      > greatest(0.01, abs(coalesce(im.total_cost, 0)) * 0.05);

  update public.inventory_movements im
  set
    unit_cost = round(coalesce(b.unit_cost, 0), 6),
    total_cost = round(coalesce(im.quantity, 0) * round(coalesce(b.unit_cost, 0), 6), 6)
  from public.batches b
  where im.id in (select movement_id from tmp_cogs_fix_movements)
    and b.id = im.batch_id;

  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_purchase_in_immutable') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_purchase_in_immutable;
  end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_inventory_movements_forbid_modify_posted') then
    alter table public.inventory_movements enable trigger trg_inventory_movements_forbid_modify_posted;
  end if;

  if to_regclass('public.journal_entries') is not null and to_regclass('public.journal_lines') is not null then
    for r in
      select im.id as movement_id, im.movement_type, im.total_cost, im.warehouse_id, je.id as entry_id
      from public.inventory_movements im
      left join public.journal_entries je
        on je.source_table = 'inventory_movements'
       and je.source_id = im.id::text
       and je.status = 'posted'
      where im.id in (select movement_id from tmp_cogs_fix_movements)
    loop
      if r.entry_id is null then
        continue;
      end if;

      v_fix_source_uuid := public.uuid_from_text(concat('cogsfix:sale_out:', r.movement_id::text));
      if exists (
        select 1
        from public.journal_entries je2
        where je2.source_table = 'ledger_repairs'
          and je2.source_id = v_fix_source_uuid::text
          and je2.source_event = 'fix_sale_out_cogs'
      ) then
        continue;
      end if;

      select greatest(coalesce(sum(jl.debit), 0), coalesce(sum(jl.credit), 0))
      into v_posted_total
      from public.journal_lines jl
      where jl.journal_entry_id = r.entry_id;

      v_delta := public._money_round(coalesce(r.total_cost, 0) - coalesce(v_posted_total, 0));
      if abs(coalesce(v_delta, 0)) <= 0.01 then
        continue;
      end if;

      v_branch := coalesce(public.branch_from_warehouse(r.warehouse_id), public.get_default_branch_id());
      v_company := coalesce(public.company_from_branch(v_branch), public.get_default_company_id());

      insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status, branch_id, company_id)
      values (
        now(),
        concat('Fix COGS delta for movement ', r.movement_id::text),
        'ledger_repairs',
        v_fix_source_uuid::text,
        'fix_sale_out_cogs',
        auth.uid(),
        'posted',
        v_branch,
        v_company
      )
      returning id into v_entry_id;

      if r.movement_type = 'return_in' then
        if v_delta > 0 then
          insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
          values
            (v_entry_id, v_inventory, v_delta, 0, 'Inventory restore (COGS fix)'),
            (v_entry_id, v_cogs, 0, v_delta, 'Reverse COGS (fix)');
        else
          insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
          values
            (v_entry_id, v_cogs, -v_delta, 0, 'Reverse COGS (fix)'),
            (v_entry_id, v_inventory, 0, -v_delta, 'Inventory restore (COGS fix)');
        end if;
      else
        if v_delta > 0 then
          insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
          values
            (v_entry_id, v_cogs, v_delta, 0, 'COGS (fix)'),
            (v_entry_id, v_inventory, 0, v_delta, 'Inventory decrease (fix)');
        else
          insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
          values
            (v_entry_id, v_inventory, -v_delta, 0, 'Inventory decrease (fix)'),
            (v_entry_id, v_cogs, 0, -v_delta, 'COGS (fix)');
        end if;
      end if;

      perform public.check_journal_entry_balance(v_entry_id);
    end loop;
  end if;

  select min(o.created_at), max(o.created_at)
  into v_min, v_max
  from public.orders o
  join public.inventory_movements im
    on im.reference_table = 'orders'
   and im.reference_id = o.id::text
  where im.id in (select movement_id from tmp_cogs_fix_movements);

  if v_min is not null and v_max is not null then
    perform public.rebuild_order_item_cogs_from_movements(v_min, v_max);
  end if;
end $$;

select pg_sleep(0.5);
notify pgrst, 'reload schema';
