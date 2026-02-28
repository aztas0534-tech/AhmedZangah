-- Restore import_expenses accounting system
-- The repair migration 20260204214848 dropped:
--   1. payment_method column
--   2. post_import_expense() function
--   3. trg_post_import_expense() trigger function
--   4. trg_import_expenses_post trigger
-- This migration restores them with branch/company-aware journal entries.

set app.allow_ledger_ddl = '1';

-- 1) Re-add payment_method column
do $$
begin
  if to_regclass('public.import_expenses') is not null then
    begin
      alter table public.import_expenses
        add column payment_method text default 'cash';
    exception when duplicate_column then
      null;
    end;

    update public.import_expenses
    set payment_method = 'cash'
    where payment_method is null;

    begin
      alter table public.import_expenses
        drop constraint if exists import_expenses_payment_method_check;
      alter table public.import_expenses
        add constraint import_expenses_payment_method_check
        check (payment_method in ('cash','bank'));
    exception when others then
      null;
    end;
  end if;
end $$;

-- 2) Re-create post_import_expense() with branch/company support
create or replace function public.post_import_expense(p_import_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ie record;
  v_ship record;
  v_amount numeric;
  v_entry_id uuid;
  v_ap uuid;
  v_cash uuid;
  v_bank uuid;
  v_clearing uuid;
  v_credit_account uuid;
  v_event text;
  v_occurred_at timestamptz;
  v_settings jsonb;
  v_accounts jsonb;
  v_branch uuid;
  v_company uuid;
begin
  if p_import_expense_id is null then
    raise exception 'p_import_expense_id is required';
  end if;

  select *
  into v_ie
  from public.import_expenses
  where id = p_import_expense_id;

  if not found then
    raise exception 'import expense not found';
  end if;

  v_amount := coalesce(v_ie.amount, 0) * coalesce(v_ie.exchange_rate, 1);
  if v_amount <= 0 then
    return;
  end if;

  v_occurred_at := coalesce(v_ie.paid_at::timestamptz, v_ie.created_at, now());

  -- Look up standard accounts
  v_ap := public.get_account_id_by_code('2010');
  v_cash := public.get_account_id_by_code('1010');
  v_bank := public.get_account_id_by_code('1020');
  v_clearing := public.get_account_id_by_code('2060');

  -- Override clearing account from app_settings if configured
  if to_regclass('public.app_settings') is not null then
    select s.data
    into v_settings
    from public.app_settings s
    where s.id in ('singleton','app')
    order by (s.id = 'singleton') desc
    limit 1;

    v_accounts := coalesce(v_settings->'settings'->'accounting_accounts', v_settings->'accounting_accounts', '{}'::jsonb);
    begin
      v_clearing := coalesce(nullif(v_accounts->>'landed_cost_clearing', '')::uuid, v_clearing);
    exception when others then
      null;
    end;
  end if;

  if v_clearing is null then
    raise exception 'landed cost clearing account (2060) not found';
  end if;

  -- Determine event type: paid vs accrual
  if v_ie.paid_at is not null then
    v_event := 'paid';
    v_credit_account := case when coalesce(v_ie.payment_method, 'cash') = 'bank' then v_bank else v_cash end;
  else
    v_event := 'accrual';
    v_credit_account := v_ap;
  end if;

  -- Remove opposite event entries (paid replaces accrual, accrual replaces paid)
  if v_event = 'paid' then
    delete from public.journal_lines jl
    using public.journal_entries je
    where jl.journal_entry_id = je.id
      and je.source_table = 'import_expenses'
      and je.source_id = p_import_expense_id::text
      and je.source_event = 'accrual';
    delete from public.journal_entries je
    where je.source_table = 'import_expenses'
      and je.source_id = p_import_expense_id::text
      and je.source_event = 'accrual';
  else
    delete from public.journal_lines jl
    using public.journal_entries je
    where jl.journal_entry_id = je.id
      and je.source_table = 'import_expenses'
      and je.source_id = p_import_expense_id::text
      and je.source_event = 'paid';
    delete from public.journal_entries je
    where je.source_table = 'import_expenses'
      and je.source_id = p_import_expense_id::text
      and je.source_event = 'paid';
  end if;

  -- Resolve branch/company from shipment warehouse
  v_branch := null;
  v_company := null;
  begin
    select s.*
    into v_ship
    from public.import_shipments s
    where s.id = v_ie.shipment_id;

    if found and v_ship.destination_warehouse_id is not null then
      v_branch := coalesce(public.branch_from_warehouse(v_ship.destination_warehouse_id), public.get_default_branch_id());
      v_company := coalesce(public.company_from_branch(v_branch), public.get_default_company_id());
    end if;
  exception when others then
    v_branch := public.get_default_branch_id();
    v_company := public.get_default_company_id();
  end;

  -- Upsert journal entry (idempotent)
  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, branch_id, company_id)
  values (
    v_occurred_at,
    concat('Import expense ', coalesce(v_ie.invoice_number, v_ie.id::text)),
    'import_expenses',
    p_import_expense_id::text,
    v_event,
    coalesce(v_ie.created_by, auth.uid()),
    v_branch,
    v_company
  )
  on conflict (source_table, source_id, source_event)
  do update set entry_date = excluded.entry_date, memo = excluded.memo
  returning id into v_entry_id;

  -- Replace lines
  delete from public.journal_lines jl where jl.journal_entry_id = v_entry_id;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values
    (v_entry_id, v_clearing, v_amount, 0, 'Landed cost service'),
    (v_entry_id, v_credit_account, 0, v_amount, case when v_event = 'paid' then 'Cash/Bank paid' else 'Accounts payable' end);

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;

revoke all on function public.post_import_expense(uuid) from public;
revoke execute on function public.post_import_expense(uuid) from anon;
revoke execute on function public.post_import_expense(uuid) from authenticated;
grant execute on function public.post_import_expense(uuid) to service_role;

-- 3) Re-create trigger function
create or replace function public.trg_post_import_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    if new.amount is not distinct from old.amount
      and new.exchange_rate is not distinct from old.exchange_rate
      and new.paid_at is not distinct from old.paid_at
      and new.payment_method is not distinct from old.payment_method
      and new.invoice_number is not distinct from old.invoice_number then
      return new;
    end if;
  end if;

  perform public.post_import_expense(new.id);
  return new;
end;
$$;

revoke all on function public.trg_post_import_expense() from public;
revoke execute on function public.trg_post_import_expense() from anon;
revoke execute on function public.trg_post_import_expense() from authenticated;
grant execute on function public.trg_post_import_expense() to service_role;

-- 4) Re-create trigger
do $$
begin
  if to_regclass('public.import_expenses') is not null then
    drop trigger if exists trg_import_expenses_post on public.import_expenses;
    create trigger trg_import_expenses_post
    after insert or update on public.import_expenses
    for each row execute function public.trg_post_import_expense();
  end if;
end $$;

notify pgrst, 'reload schema';
