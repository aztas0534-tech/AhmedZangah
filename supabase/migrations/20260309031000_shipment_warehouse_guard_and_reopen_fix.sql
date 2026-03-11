-- =======================================================================
-- Shipment Module Improvements
--
-- Fix 1: Add warehouse mismatch guard on purchase_receipts
--   Prevents linking a receipt to a shipment when the receipt's
--   warehouse_id differs from the shipment's destination_warehouse_id.
--
-- Fix 2: Save original pre-close unit_cost on batches so that
--   reopen_import_shipment can revert to the TRUE original cost
--   (not the landed cost that overwrote purchase_receipt_items.unit_cost).
-- =======================================================================

set app.allow_ledger_ddl = '1';

-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ FIX 1: Add warehouse check to the existing guard trigger          │
-- └─────────────────────────────────────────────────────────────────────┘
create or replace function public.trg_guard_purchase_receipt_import_shipment_po()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship_id uuid;
  v_po_id uuid;
  v_has_allowlist boolean;
  v_ship_warehouse uuid;
begin
  if tg_op = 'DELETE' then
    return old;
  end if;

  v_ship_id := new.import_shipment_id;
  if v_ship_id is null then
    return new;
  end if;

  v_po_id := new.purchase_order_id;
  if v_po_id is null then
    return new;
  end if;

  -- ▶ NEW: Check warehouse match
  select s.destination_warehouse_id
  into v_ship_warehouse
  from public.import_shipments s
  where s.id = v_ship_id;

  if v_ship_warehouse is not null
     and new.warehouse_id is not null
     and new.warehouse_id <> v_ship_warehouse then
    raise exception 'مستودع الاستلام (%) لا يطابق مستودع وجهة الشحنة (%). يجب أن يكون نفس المستودع.',
      new.warehouse_id, v_ship_warehouse
      using errcode = 'P0001';
  end if;

  -- Existing: PO allowlist check
  if to_regclass('public.import_shipment_purchase_orders') is not null then
    select exists(
      select 1
      from public.import_shipment_purchase_orders l
      where l.shipment_id = v_ship_id
    )
    into v_has_allowlist;

    if v_has_allowlist then
      if not exists(
        select 1
        from public.import_shipment_purchase_orders l
        where l.shipment_id = v_ship_id
          and l.purchase_order_id = v_po_id
      ) then
        raise exception 'Purchase order % is not allowed for shipment %', v_po_id, v_ship_id;
      end if;
    end if;
  end if;

  -- Existing: Prevent duplicate PO per shipment
  if exists(
    select 1
    from public.purchase_receipts pr
    where pr.import_shipment_id = v_ship_id
      and pr.purchase_order_id = v_po_id
      and pr.id <> new.id
  ) then
    raise exception 'Purchase order % is already linked to shipment %', v_po_id, v_ship_id;
  end if;

  return new;
end;
$$;


-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ FIX 2: Add pre_close_unit_cost column to batches                  │
-- └─────────────────────────────────────────────────────────────────────┘
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'batches'
      and column_name = 'pre_close_unit_cost'
  ) then
    alter table public.batches
      add column pre_close_unit_cost numeric;
    comment on column public.batches.pre_close_unit_cost is
      'Original unit_cost BEFORE shipment close overwrites it with landed cost. Used by reopen to accurately revert.';
  end if;
end $$;

-- Also add to purchase_receipt_items for completeness
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'purchase_receipt_items'
      and column_name = 'pre_close_unit_cost'
  ) then
    alter table public.purchase_receipt_items
      add column pre_close_unit_cost numeric;
    comment on column public.purchase_receipt_items.pre_close_unit_cost is
      'Original unit_cost BEFORE shipment close overwrites it. Used by reopen to accurately revert.';
  end if;
end $$;


-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ FIX 3: Update trg_close_import_shipment to save pre-close costs   │
-- │        before overwriting with landed cost                         │
-- └─────────────────────────────────────────────────────────────────────┘
create or replace function public.trg_close_import_shipment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_im record;
  v_batch record;
  v_out record;
  v_qty_linked numeric;
  v_new_unit_base numeric;
  v_close_at timestamptz;
  v_total_delta_sold numeric := 0;
  v_total_delta_rem numeric := 0;
  v_delta numeric;
  v_entry_id uuid;
  v_accounts jsonb;
  v_inventory uuid;
  v_cogs uuid;
  v_clearing uuid;
  v_branch uuid;
  v_company uuid;
  v_order_id uuid;
  v_total_delta numeric;
  v_sm_avg numeric;
  v_rem_qty numeric;
  v_base_currency text;
begin
  -- SET BYPASS CONFIG
  perform set_config('app.internal_shipment_close', '1', false);

  if coalesce(new.status, '') <> 'closed' then
    perform set_config('app.internal_shipment_close', '', false);
    return new;
  end if;
  if coalesce(old.status, '') = 'closed' then
    perform set_config('app.internal_shipment_close', '', false);
    return new;
  end if;
  if new.destination_warehouse_id is null then
    perform set_config('app.internal_shipment_close', '', false);
    raise exception 'destination_warehouse_id is required to close import shipment %', new.id;
  end if;
  if not exists (select 1 from public.purchase_receipts pr where pr.import_shipment_id = new.id) then
    perform set_config('app.internal_shipment_close', '', false);
    raise exception 'No linked purchase receipts for import shipment %', new.id;
  end if;

  v_base_currency := public.get_base_currency();
  v_close_at := coalesce(new.actual_arrival_date::timestamptz, now());

  -- Auto-Sync Items from Receipts
  with agg as (
    select
      pri.item_id::text as item_id,
      sum(coalesce(pri.quantity, 0))::numeric as quantity,
      case
        when sum(coalesce(pri.quantity, 0)) > 0 then
          (sum(coalesce(pri.quantity, 0) * greatest(coalesce(pri.unit_cost, 0) - coalesce(pri.transport_cost, 0) - coalesce(pri.supply_tax_cost, 0), 0)))
          / sum(coalesce(pri.quantity, 0))
        else 0
      end::numeric as unit_price_fob
    from public.purchase_receipts pr
    join public.purchase_receipt_items pri on pri.receipt_id = pr.id
    where pr.import_shipment_id = new.id
      and pr.warehouse_id = new.destination_warehouse_id
    group by pri.item_id
    having sum(coalesce(pri.quantity, 0)) > 0
  )
  insert into public.import_shipments_items(
    shipment_id, item_id, quantity, unit_price_fob, currency, expiry_date, notes, updated_at
  )
  select
    new.id, a.item_id, a.quantity,
    greatest(coalesce(a.unit_price_fob, 0), 0),
    v_base_currency, null, 'synced_from_receipts_on_close', now()
  from agg a
  on conflict (shipment_id, item_id) do update
  set
    quantity = excluded.quantity,
    unit_price_fob = case when coalesce(import_shipments_items.unit_price_fob, 0) > 0 then import_shipments_items.unit_price_fob else excluded.unit_price_fob end,
    updated_at = now();

  -- Delete Orphans
  delete from public.import_shipments_items isi
  where isi.shipment_id = new.id
    and not exists (
      select 1
      from public.purchase_receipts pr
      join public.purchase_receipt_items pri on pri.receipt_id = pr.id
      where pr.import_shipment_id = new.id
        and pr.warehouse_id = new.destination_warehouse_id
        and pri.item_id::text = isi.item_id::text
      group by pri.item_id
      having sum(coalesce(pri.quantity, 0)) > 0
    );

  -- Calculate landed cost
  perform public.calculate_shipment_landed_cost(new.id);

  -- VALIDATION CHECK
  for v_row in
    select
      isi.item_id::text as item_id_text,
      coalesce(isi.quantity, 0) as expected_qty
    from public.import_shipments_items isi
    where isi.shipment_id = new.id
  loop
    select coalesce(sum(pri.quantity), 0)
    into v_qty_linked
    from public.purchase_receipt_items pri
    join public.purchase_receipts pr on pr.id = pri.receipt_id
    where pr.import_shipment_id = new.id
      and pr.warehouse_id = new.destination_warehouse_id
      and pri.item_id::text = v_row.item_id_text;

    if abs(coalesce(v_qty_linked, 0) - coalesce(v_row.expected_qty, 0)) > 1e-6 then
      perform set_config('app.internal_shipment_close', '', false);
      raise exception 'Linked receipt quantity mismatch for item % (expected %, got %)', v_row.item_id_text, v_row.expected_qty, v_qty_linked;
    end if;
  end loop;

  -- COST UPDATE LOOP
  for v_row in
    select
      pr.id as receipt_id,
      pri.id as receipt_item_id,
      pri.item_id::text as item_id_text,
      coalesce(pri.quantity, 0) as qty,
      coalesce(pri.transport_cost, 0) as transport_unit_raw,
      coalesce(pri.supply_tax_cost, 0) as tax_unit_raw,
      coalesce(isi.landing_cost_per_unit, 0) as landed_unit_base,
      po.currency as po_currency,
      coalesce(po.fx_rate, 1) as po_fx_rate
    from public.purchase_receipts pr
    join public.purchase_receipt_items pri on pri.receipt_id = pr.id
    join public.purchase_orders po on po.id = pr.purchase_order_id
    join public.import_shipments_items isi
      on isi.shipment_id = new.id and isi.item_id::text = pri.item_id::text
    where pr.import_shipment_id = new.id
      and pr.warehouse_id = new.destination_warehouse_id
  loop
    if v_row.po_currency <> v_base_currency and v_row.po_fx_rate > 0 then
        v_new_unit_base := v_row.landed_unit_base
                          + (v_row.transport_unit_raw * v_row.po_fx_rate)
                          + (v_row.tax_unit_raw * v_row.po_fx_rate);
    else
        v_new_unit_base := v_row.landed_unit_base
                          + v_row.transport_unit_raw
                          + v_row.tax_unit_raw;
    end if;

    select im.*
    into v_im
    from public.inventory_movements im
    where im.reference_table = 'purchase_receipts'
      and im.reference_id = v_row.receipt_id::text
      and im.item_id::text = v_row.item_id_text
      and im.movement_type = 'purchase_in'
    order by im.occurred_at asc
    limit 1
    for update;

    if not found then
      perform set_config('app.internal_shipment_close', '', false);
      raise exception 'Missing purchase_in movement for receipt % item %', v_row.receipt_id, v_row.item_id_text;
    end if;

    if abs(coalesce(v_im.quantity, 0) - coalesce(v_row.qty, 0)) > 1e-6 then
      perform set_config('app.internal_shipment_close', '', false);
      raise exception 'Receipt movement quantity mismatch for receipt % item % (receipt %, movement %)',
        v_row.receipt_id, v_row.item_id_text, v_row.qty, v_im.quantity;
    end if;

    select b.* into v_batch
    from public.batches b
    where b.id = v_im.batch_id
    for update;

    if not found then
      perform set_config('app.internal_shipment_close', '', false);
      raise exception 'Batch not found for movement %', v_im.id;
    end if;

    -- ▶ NEW: Save original cost BEFORE overwriting
    update public.purchase_receipt_items
    set pre_close_unit_cost = case
          when pre_close_unit_cost is null then unit_cost  -- only save first time
          else pre_close_unit_cost
        end
    where id = v_row.receipt_item_id;

    update public.batches
    set pre_close_unit_cost = case
          when pre_close_unit_cost is null then unit_cost  -- only save first time
          else pre_close_unit_cost
        end
    where id = v_batch.id;

    -- Retroactive COGS adjustments for already-sold items
    for v_out in
      select im2.*
      from public.inventory_movements im2
      where im2.batch_id = v_im.batch_id
        and im2.movement_type in ('sale_out','wastage_out','expired_out')
        and im2.occurred_at < v_close_at
      for update
    loop
      v_delta := (v_new_unit_base - coalesce(v_out.unit_cost, 0)) * coalesce(v_out.quantity, 0);
      v_total_delta_sold := v_total_delta_sold + v_delta;

      if v_out.reference_table = 'orders' then
        begin
          v_order_id := nullif(v_out.reference_id, '')::uuid;
        exception when others then
          v_order_id := null;
        end;

        if v_order_id is not null and to_regclass('public.order_item_cogs') is not null then
          update public.order_item_cogs
          set total_cost = coalesce(total_cost, 0) + v_delta,
              unit_cost = case
                when coalesce(quantity, 0) > 0 then (coalesce(total_cost, 0) + v_delta) / quantity
                else unit_cost
              end
          where order_id = v_order_id
            and item_id::text = v_row.item_id_text;
        end if;
      end if;
    end loop;

    v_rem_qty := greatest(coalesce(v_batch.quantity_received, 0) - coalesce(v_batch.quantity_consumed, 0), 0);
    v_total_delta_rem := v_total_delta_rem + ((v_new_unit_base - coalesce(v_im.unit_cost, 0)) * v_rem_qty);

    -- Now overwrite with landed cost
    update public.purchase_receipt_items
    set unit_cost = v_new_unit_base,
        total_cost = coalesce(v_row.qty, 0) * v_new_unit_base
    where id = v_row.receipt_item_id;

    update public.batches
    set unit_cost = v_new_unit_base,
        updated_at = now()
    where id = v_batch.id;
  end loop;

  -- Recalculate avg_cost per warehouse
  for v_row in
    select distinct pri.item_id::text as item_id_text
    from public.purchase_receipt_items pri
    join public.purchase_receipts pr on pr.id = pri.receipt_id
    where pr.import_shipment_id = new.id
      and pr.warehouse_id = new.destination_warehouse_id
  loop
    select
      case when sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0), 0)) > 0 then
        sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0), 0) * coalesce(b.unit_cost,0))
        / sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0), 0))
      else 0 end
    into v_sm_avg
    from public.batches b
    where b.item_id::text = v_row.item_id_text
      and b.warehouse_id = new.destination_warehouse_id;

    update public.stock_management
    set avg_cost = coalesce(v_sm_avg, 0),
        updated_at = now(),
        last_updated = now()
    where item_id::text = v_row.item_id_text
      and warehouse_id = new.destination_warehouse_id;
  end loop;

  -- JOURNAL ENTRIES
  v_total_delta := coalesce(v_total_delta_sold, 0) + coalesce(v_total_delta_rem, 0);
  if abs(coalesce(v_total_delta, 0)) > 1e-6 then
    -- COGS adjust entry (for already-sold items)
    if abs(coalesce(v_total_delta_sold, 0)) > 1e-6 and not exists (
      select 1 from public.journal_entries je
      where je.source_table = 'import_shipments'
      and je.source_id = new.id::text
      and je.source_event = 'landed_cost_cogs_adjust'
    ) then
      select s.data->'settings'->'accounting_accounts' into v_accounts
      from public.app_settings s where s.id = 'app';
      if v_accounts is null then
        select s.data->'accounting_accounts' into v_accounts
        from public.app_settings s where s.id = 'singleton';
      end if;

      v_inventory := null;
      if v_accounts is not null and nullif(v_accounts->>'inventory', '') is not null then
        begin v_inventory := (v_accounts->>'inventory')::uuid;
        exception when others then v_inventory := public.get_account_id_by_code(v_accounts->>'inventory'); end;
      end if;
      v_inventory := coalesce(v_inventory, public.get_account_id_by_code('1410'));

      v_cogs := null;
      if v_accounts is not null and nullif(v_accounts->>'cogs', '') is not null then
        begin v_cogs := (v_accounts->>'cogs')::uuid;
        exception when others then v_cogs := public.get_account_id_by_code(v_accounts->>'cogs'); end;
      end if;
      v_cogs := coalesce(v_cogs, public.get_account_id_by_code('5010'));

      if v_inventory is null or v_cogs is null then
        perform set_config('app.internal_shipment_close', '', false);
        raise exception 'Missing accounting accounts for landed cost COGS adjust';
      end if;

      v_branch := coalesce(public.branch_from_warehouse(new.destination_warehouse_id), public.get_default_branch_id());
      v_company := coalesce(public.company_from_branch(v_branch), public.get_default_company_id());

      insert into public.journal_entries(
        id, source_table, source_id, source_event, entry_date, memo, created_by, branch_id, company_id
      ) values (
        gen_random_uuid(), 'import_shipments', new.id::text, 'landed_cost_cogs_adjust',
        v_close_at, concat('Import landed cost COGS adjust ', coalesce(new.reference_number, new.id::text)),
        new.created_by, v_branch, v_company
      ) returning id into v_entry_id;

      if v_total_delta_sold > 0 then
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo) values
          (v_entry_id, v_cogs, v_total_delta_sold, 0, 'COGS increase from landed cost'),
          (v_entry_id, v_inventory, 0, v_total_delta_sold, 'Inventory reduction (sold already)');
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo) values
          (v_entry_id, v_inventory, -v_total_delta_sold, 0, 'Inventory increase (sold already)'),
          (v_entry_id, v_cogs, 0, -v_total_delta_sold, 'COGS decrease from landed cost');
      end if;
      perform public.check_journal_entry_balance(v_entry_id);
    end if;

    -- Clearing entry (for remaining inventory)
    if abs(coalesce(v_total_delta_rem, 0)) > 1e-6 and not exists (
      select 1 from public.journal_entries je
      where je.source_table = 'import_shipments'
      and je.source_id = new.id::text
      and je.source_event = 'landed_cost_close'
    ) then
      select s.data->'settings'->'accounting_accounts' into v_accounts
      from public.app_settings s where s.id = 'app';
      if v_accounts is null then
        select s.data->'accounting_accounts' into v_accounts
        from public.app_settings s where s.id = 'singleton';
      end if;

      v_inventory := null;
      if v_accounts is not null and nullif(v_accounts->>'inventory', '') is not null then
        begin v_inventory := (v_accounts->>'inventory')::uuid;
        exception when others then v_inventory := public.get_account_id_by_code(v_accounts->>'inventory'); end;
      end if;
      v_inventory := coalesce(v_inventory, public.get_account_id_by_code('1410'));

      v_clearing := null;
      if v_accounts is not null and nullif(v_accounts->>'landed_cost_clearing', '') is not null then
        begin v_clearing := (v_accounts->>'landed_cost_clearing')::uuid;
        exception when others then v_clearing := public.get_account_id_by_code(v_accounts->>'landed_cost_clearing'); end;
      end if;
      v_clearing := coalesce(v_clearing, public.get_account_id_by_code('2060'));

      if v_inventory is null or v_clearing is null then
        perform set_config('app.internal_shipment_close', '', false);
        raise exception 'Missing accounting accounts for landed cost close';
      end if;

      v_branch := coalesce(public.branch_from_warehouse(new.destination_warehouse_id), public.get_default_branch_id());
      v_company := coalesce(public.company_from_branch(v_branch), public.get_default_company_id());

      insert into public.journal_entries(
        id, source_table, source_id, source_event, entry_date, memo, created_by, branch_id, company_id
      ) values (
        gen_random_uuid(), 'import_shipments', new.id::text, 'landed_cost_close',
        v_close_at, concat('Import landed cost close ', coalesce(new.reference_number, new.id::text)),
        new.created_by, v_branch, v_company
      ) returning id into v_entry_id;

      if v_total_delta_rem > 0 then
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo) values
          (v_entry_id, v_inventory, v_total_delta_rem, 0, 'Landed cost added to remaining inventory'),
          (v_entry_id, v_clearing, 0, v_total_delta_rem, 'Landed cost clearing');
      else
        insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo) values
          (v_entry_id, v_clearing, -v_total_delta_rem, 0, 'Landed cost clearing'),
          (v_entry_id, v_inventory, 0, -v_total_delta_rem, 'Landed cost removed from remaining inventory');
      end if;
      perform public.check_journal_entry_balance(v_entry_id);
    end if;
  end if;

  perform set_config('app.internal_shipment_close', '', false);
  return new;
end;
$$;

-- Ensure trigger is correctly set up
drop trigger if exists trg_close_import_shipment on public.import_shipments;
create trigger trg_close_import_shipment
after update on public.import_shipments
for each row
execute function public.trg_close_import_shipment();


-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ FIX 4: Update reopen to use pre_close_unit_cost                   │
-- └─────────────────────────────────────────────────────────────────────┘
create or replace function public.reopen_import_shipment(
  p_shipment_id uuid,
  p_reason text default 'correction'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_ship record;
  v_entry record;
  v_reversal_id uuid;
  v_reversal_count int := 0;
  v_batch_count int := 0;
  v_base_currency text;
  v_now timestamptz;
  v_user_id uuid;
  v_branch uuid;
  v_company uuid;
begin
  if not public.has_admin_permission('procurement.manage') then
    raise exception 'not allowed';
  end if;

  if p_shipment_id is null then
    raise exception 'p_shipment_id is required';
  end if;

  v_user_id := auth.uid();
  v_base_currency := public.get_base_currency();
  v_now := now();

  select * into v_ship
  from public.import_shipments s
  where s.id = p_shipment_id
  for update;

  if not found then
    raise exception 'shipment not found';
  end if;

  if v_ship.status <> 'closed' then
    raise exception 'الشحنة ليست مغلقة. لا يمكن إعادة فتح إلا شحنة مغلقة.';
  end if;

  v_branch := coalesce(public.branch_from_warehouse(v_ship.destination_warehouse_id), public.get_default_branch_id());
  v_company := coalesce(public.company_from_branch(v_branch), public.get_default_company_id());

  -- Step 1: Create reversal journal entries
  for v_entry in
    select je.id, je.source_event, je.memo
    from public.journal_entries je
    where je.source_table = 'import_shipments'
      and je.source_id = p_shipment_id::text
      and je.source_event in ('landed_cost_cogs_adjust', 'landed_cost_close')
  loop
    insert into public.journal_entries(
      id, source_table, source_id, source_event, entry_date, memo, created_by, branch_id, company_id
    ) values (
      gen_random_uuid(), 'import_shipments', p_shipment_id::text,
      v_entry.source_event || '_reversal', v_now,
      concat('عكس قيد: ', coalesce(v_entry.memo, ''), ' | سبب: ', coalesce(p_reason, 'correction')),
      v_user_id, v_branch, v_company
    ) returning id into v_reversal_id;

    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    select v_reversal_id, jl.account_id, jl.credit, jl.debit,
      concat('عكس: ', coalesce(jl.line_memo, ''))
    from public.journal_lines jl
    where jl.journal_entry_id = v_entry.id;

    perform public.check_journal_entry_balance(v_reversal_id);
    v_reversal_count := v_reversal_count + 1;
  end loop;

  -- Step 2: Set bypass configs
  perform set_config('app.internal_shipment_close', '1', false);
  perform set_config('app.internal_shipment_reopen', '1', false);

  -- Step 3: ▶ FIXED — Revert batch costs to ORIGINAL pre-close cost (not the landed cost)
  update public.batches b
  set
    unit_cost = coalesce(b.pre_close_unit_cost, pri.unit_cost, b.unit_cost),
    pre_close_unit_cost = null,  -- clear the snapshot
    updated_at = v_now
  from public.purchase_receipt_items pri
  join public.purchase_receipts pr on pr.id = pri.receipt_id
  where pr.import_shipment_id = p_shipment_id
    and pr.warehouse_id = v_ship.destination_warehouse_id
    and b.receipt_id = pr.id
    and b.item_id::text = pri.item_id::text;

  get diagnostics v_batch_count = row_count;

  -- Also revert purchase_receipt_items costs
  update public.purchase_receipt_items pri
  set
    unit_cost = coalesce(pri.pre_close_unit_cost, pri.unit_cost),
    total_cost = coalesce(pri.quantity, 0) * coalesce(pri.pre_close_unit_cost, pri.unit_cost),
    pre_close_unit_cost = null  -- clear the snapshot
  from public.purchase_receipts pr
  where pr.id = pri.receipt_id
    and pr.import_shipment_id = p_shipment_id
    and pr.warehouse_id = v_ship.destination_warehouse_id
    and pri.pre_close_unit_cost is not null;

  -- Step 4: Recalculate avg_cost
  with affected_items as (
    select distinct pri.item_id::text as item_id
    from public.purchase_receipt_items pri
    join public.purchase_receipts pr on pr.id = pri.receipt_id
    where pr.import_shipment_id = p_shipment_id
      and pr.warehouse_id = v_ship.destination_warehouse_id
  ),
  calc as (
    select
      b.item_id::text as item_id,
      b.warehouse_id,
      case when sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0), 0)) > 0 then
        sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0), 0) * coalesce(b.unit_cost, 0))
        / sum(greatest(coalesce(b.quantity_received, 0) - coalesce(b.quantity_consumed, 0), 0))
      else 0 end as avg_cost
    from public.batches b
    join affected_items ai on ai.item_id = b.item_id::text
    where b.warehouse_id = v_ship.destination_warehouse_id
    group by b.item_id::text, b.warehouse_id
  )
  update public.stock_management sm
  set avg_cost = round(coalesce(c.avg_cost, sm.avg_cost), 6),
      updated_at = v_now,
      last_updated = v_now
  from calc c
  where sm.item_id::text = c.item_id
    and sm.warehouse_id = c.warehouse_id;

  -- Step 5: Reset landed_cost_per_unit
  update public.import_shipments_items
  set landing_cost_per_unit = null, updated_at = v_now
  where shipment_id = p_shipment_id;

  -- Step 6: Set status back to 'ordered'
  update public.import_shipments
  set status = 'ordered', updated_at = v_now
  where id = p_shipment_id;

  -- Clear bypass configs
  perform set_config('app.internal_shipment_reopen', '', false);
  perform set_config('app.internal_shipment_close', '', false);

  -- Step 7: Delete original close-time journal entries (keep reversals as audit trail)
  delete from public.journal_entries
  where source_table = 'import_shipments'
    and source_id = p_shipment_id::text
    and source_event in ('landed_cost_cogs_adjust', 'landed_cost_close');

  return jsonb_build_object(
    'status', 'reopened',
    'shipment_id', p_shipment_id::text,
    'reversals_created', v_reversal_count,
    'batches_reverted', v_batch_count,
    'reason', coalesce(p_reason, 'correction'),
    'reopened_at', v_now,
    'reopened_by', v_user_id
  );
end;
$fn$;

revoke all on function public.reopen_import_shipment(uuid, text) from public;
grant execute on function public.reopen_import_shipment(uuid, text) to authenticated;

notify pgrst, 'reload schema';
