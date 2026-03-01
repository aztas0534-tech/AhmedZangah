set app.allow_ledger_ddl = '1';

-- ===========================================================================
-- PART 1: Block DELETE on closed/delivered shipments + allow reopen bypass
-- ===========================================================================
create or replace function public.trg_lock_closed_import_shipments()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Block DELETE on closed/delivered shipments
  if tg_op = 'DELETE' then
    if coalesce(old.status, '') in ('closed', 'delivered') then
      raise exception 'لا يمكن حذف شحنة مغلقة أو مُسلَّمة. استخدم إعادة الفتح أولاً إذا كنت تحتاج لتعديلها.'
        using errcode = 'P0001';
    end if;
    return old;
  end if;

  -- Block UPDATE on closed shipments (with reopen bypass)
  if tg_op = 'UPDATE' then
    -- Allow reopen operation
    begin
      if coalesce(current_setting('app.internal_shipment_reopen', true), '') = '1' then
        return new;
      end if;
    exception when others then
      null;
    end;

    if coalesce(old.status, '') = 'closed' then
      raise exception 'الشحنة مغلقة ولا يمكن تعديلها. استخدم إعادة الفتح أولاً.'
        using errcode = 'P0001';
    end if;
    if coalesce(old.status, '') = 'delivered' and coalesce(new.status, '') <> 'closed' then
      raise exception 'الشحنة مُسلَّمة ولا يمكن تغيير حالتها إلا للإغلاق.'
        using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

-- Re-create the trigger to include DELETE
drop trigger if exists trg_lock_closed_import_shipments on public.import_shipments;
create trigger trg_lock_closed_import_shipments
before update or delete on public.import_shipments
for each row
execute function public.trg_lock_closed_import_shipments();

-- ===========================================================================
-- PART 2: Detect orphaned journal entries from deleted shipments
-- ===========================================================================
create or replace function public.detect_orphaned_shipment_entries()
returns table(
  journal_entry_id uuid,
  source_id text,
  source_event text,
  entry_date timestamptz,
  memo text,
  total_debit numeric,
  status text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    je.id as journal_entry_id,
    je.source_id,
    je.source_event,
    je.entry_date,
    je.memo,
    (select coalesce(sum(jl.debit), 0) from public.journal_lines jl where jl.journal_entry_id = je.id) as total_debit,
    'orphaned'::text as status
  from public.journal_entries je
  where je.source_table = 'import_shipments'
    and not exists (
      select 1 from public.import_shipments s
      where s.id::text = je.source_id
    );
$$;

revoke all on function public.detect_orphaned_shipment_entries() from public;
grant execute on function public.detect_orphaned_shipment_entries() to authenticated;

-- ===========================================================================
-- PART 3: Reopen closed shipment (best practice: reversal approach)
-- ===========================================================================
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
  -- Permission check
  if not public.has_admin_permission('procurement.manage') then
    raise exception 'not allowed';
  end if;

  if p_shipment_id is null then
    raise exception 'p_shipment_id is required';
  end if;

  v_user_id := auth.uid();
  v_base_currency := public.get_base_currency();
  v_now := now();

  -- Lock the shipment
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

  -- Step 1: Create reversal journal entries for all close-related entries
  for v_entry in
    select je.id, je.source_event, je.memo
    from public.journal_entries je
    where je.source_table = 'import_shipments'
      and je.source_id = p_shipment_id::text
      and je.source_event in ('landed_cost_cogs_adjust', 'landed_cost_close')
  loop
    -- Create reversal entry
    insert into public.journal_entries(
      id, source_table, source_id, source_event, entry_date, memo,
      created_by, branch_id, company_id
    ) values (
      gen_random_uuid(),
      'import_shipments',
      p_shipment_id::text,
      v_entry.source_event || '_reversal',
      v_now,
      concat('عكس قيد: ', coalesce(v_entry.memo, ''), ' | سبب: ', coalesce(p_reason, 'correction')),
      v_user_id,
      v_branch,
      v_company
    ) returning id into v_reversal_id;

    -- Copy all lines but swap debit/credit
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    select
      v_reversal_id,
      jl.account_id,
      jl.credit,  -- swap: original credit becomes reversal debit
      jl.debit,   -- swap: original debit becomes reversal credit
      concat('عكس: ', coalesce(jl.line_memo, ''))
    from public.journal_lines jl
    where jl.journal_entry_id = v_entry.id;

    perform public.check_journal_entry_balance(v_reversal_id);

    v_reversal_count := v_reversal_count + 1;
  end loop;

  -- Step 2: Set bypass configs
  perform set_config('app.internal_shipment_close', '1', false);
  perform set_config('app.internal_shipment_reopen', '1', false);

  -- Step 3: Revert batch costs to original receipt effective cost
  update public.batches b
  set
    unit_cost = coalesce(pri.unit_cost, b.unit_cost),
    updated_at = v_now
  from public.purchase_receipt_items pri
  join public.purchase_receipts pr on pr.id = pri.receipt_id
  where pr.import_shipment_id = p_shipment_id
    and pr.warehouse_id = v_ship.destination_warehouse_id
    and b.receipt_id = pr.id
    and b.item_id::text = pri.item_id::text;

  get diagnostics v_batch_count = row_count;

  -- Step 4: Recalculate avg_cost in stock_management
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

  -- Step 5: Reset landed_cost_per_unit in shipment items
  update public.import_shipments_items
  set landing_cost_per_unit = null,
      updated_at = v_now
  where shipment_id = p_shipment_id;

  -- Step 6: Set status back to 'ordered'
  update public.import_shipments
  set status = 'ordered',
      updated_at = v_now
  where id = p_shipment_id;

  -- Clear bypass configs
  perform set_config('app.internal_shipment_reopen', '', false);
  perform set_config('app.internal_shipment_close', '', false);

  -- Step 7: Delete the original close-time journal entries
  -- (We keep the reversals as permanent audit trail)
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

-- ===========================================================================
-- PART 4: Detect orphaned data from previously deleted shipments
-- ===========================================================================
do $$
declare
  v_orphan_count int;
begin
  select count(*) into v_orphan_count
  from public.journal_entries je
  where je.source_table = 'import_shipments'
    and not exists (
      select 1 from public.import_shipments s
      where s.id::text = je.source_id
    );

  if v_orphan_count > 0 then
    raise notice 'WARNING: Found % orphaned journal entries from deleted shipments. Run detect_orphaned_shipment_entries() to review.', v_orphan_count;
  else
    raise notice 'OK: No orphaned shipment journal entries found.';
  end if;
end $$;

notify pgrst, 'reload schema';
