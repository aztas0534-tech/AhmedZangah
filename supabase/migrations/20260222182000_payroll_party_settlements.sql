set app.allow_ledger_ddl = '1';

do $$
begin
  if to_regclass('public.payroll_settings') is not null then
    begin
      alter table public.payroll_settings
        add column enable_party_settlements boolean not null default false;
    exception when duplicate_column then
      null;
    end;
  end if;
end $$;

do $$
begin
  if to_regclass('public.payroll_run_party_settlements') is null then
    create table public.payroll_run_party_settlements (
      id uuid primary key default gen_random_uuid(),
      run_id uuid not null references public.payroll_runs(id) on delete cascade,
      employee_id uuid not null references public.payroll_employees(id) on delete restrict,
      party_id uuid not null references public.financial_parties(id) on delete restrict,
      currency_code text,
      payable_doc_id uuid references public.party_documents(id) on delete set null,
      payable_advance_settlement_id uuid references public.settlement_headers(id) on delete set null,
      payout_doc_id uuid references public.party_documents(id) on delete set null,
      payout_settlement_id uuid references public.settlement_headers(id) on delete set null,
      created_at timestamptz not null default now(),
      created_by uuid references auth.users(id) on delete set null,
      updated_at timestamptz not null default now(),
      updated_by uuid references auth.users(id) on delete set null,
      unique (run_id, employee_id)
    );
    create index if not exists idx_payroll_run_party_settlements_run on public.payroll_run_party_settlements(run_id);
    create index if not exists idx_payroll_run_party_settlements_party on public.payroll_run_party_settlements(party_id);
  end if;
end $$;

create or replace function public.trg_payroll_run_party_settlements_touch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

do $$
begin
  if to_regclass('public.payroll_run_party_settlements') is not null then
    drop trigger if exists trg_payroll_run_party_settlements_touch on public.payroll_run_party_settlements;
    create trigger trg_payroll_run_party_settlements_touch
    before update on public.payroll_run_party_settlements
    for each row execute function public.trg_payroll_run_party_settlements_touch();
  end if;
end $$;

alter table public.payroll_run_party_settlements enable row level security;
drop policy if exists payroll_run_party_settlements_select on public.payroll_run_party_settlements;
create policy payroll_run_party_settlements_select
on public.payroll_run_party_settlements
for select
using (public.has_admin_permission('accounting.view'));

drop policy if exists payroll_run_party_settlements_write on public.payroll_run_party_settlements;
create policy payroll_run_party_settlements_write
on public.payroll_run_party_settlements
for all
using (public.has_admin_permission('accounting.manage'))
with check (public.has_admin_permission('accounting.manage'));

create or replace function public.payroll_settle_run_employees_v1(
  p_run_id uuid,
  p_occurred_at timestamptz default null,
  p_method text default 'cash',
  p_apply_advances boolean default true,
  p_pay_remaining boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings record;
  v_run record;
  v_occurred timestamptz;
  v_payable_account_id uuid;
  v_payable_account_code text;
  v_adv_account_id uuid;
  v_cash_account_code text;
  v_base text;
  v_can_approve boolean := false;
  v_needs_approval boolean := false;
  v_apply_advances boolean := true;
  v_pay_remaining boolean := true;
  v_created_payables int := 0;
  v_created_payouts int := 0;
  v_created_adv_settlements int := 0;
  v_created_payout_settlements int := 0;
  r record;
  v_party_id uuid;
  v_doc_id uuid;
  v_payable_item public.party_open_items%rowtype;
  v_payment_item public.party_open_items%rowtype;
  v_allocs jsonb;
  v_alloc_base numeric;
  v_alloc_foreign numeric;
  v_rem_base numeric;
  v_rem_foreign numeric;
  v_currency text;
  v_fx numeric;
  v_method text;
  v_settlement_id uuid;
  v_payout_amount_base numeric;
  v_payout_amount_foreign numeric;
  v_tol numeric := 0.000001;
begin
  if not public.has_admin_permission('accounting.manage') then
    raise exception 'not allowed';
  end if;

  select * into v_settings
  from public.payroll_settings
  where id = 'app';

  if not coalesce(v_settings.enable_party_settlements, false) then
    raise exception 'party settlements not enabled';
  end if;

  if p_run_id is null then
    raise exception 'run_id is required';
  end if;

  select *
  into v_run
  from public.payroll_runs pr
  where pr.id = p_run_id;

  if not found then
    raise exception 'run not found';
  end if;

  if coalesce(v_run.status,'') not in ('accrued','paid') then
    raise exception 'run must be accrued';
  end if;

  v_occurred := coalesce(p_occurred_at, now());
  if public.is_in_closed_period(v_occurred) then
    raise exception 'accounting period is closed';
  end if;

  v_can_approve := public.has_admin_permission('accounting.approve');
  v_apply_advances := coalesce(p_apply_advances, true);
  v_pay_remaining := coalesce(p_pay_remaining, true);
  if not v_can_approve then
    v_apply_advances := false;
    v_pay_remaining := false;
  end if;
  v_base := public.get_base_currency();

  v_payable_account_id := coalesce(v_settings.salary_payable_account_id, public.get_account_id_by_code('2120'));
  if v_payable_account_id is null then
    raise exception 'salary payable account missing';
  end if;
  select a.code into v_payable_account_code from public.chart_of_accounts a where a.id = v_payable_account_id;
  if v_payable_account_code is null then
    raise exception 'salary payable account code missing';
  end if;

  insert into public.party_subledger_accounts(account_id, role, is_active)
  values (v_payable_account_id, 'ap', true)
  on conflict (account_id) do update
    set role = excluded.role,
        is_active = excluded.is_active;

  v_adv_account_id := public.get_account_id_by_code('1350');
  if v_adv_account_id is null then
    raise exception 'employee advances account missing';
  end if;

  v_method := lower(nullif(trim(coalesce(p_method,'')), ''));
  if v_method is null then
    v_method := 'cash';
  end if;
  if v_method = 'card' then v_method := 'network'; end if;
  if v_method = 'bank' then v_method := 'kuraimi'; end if;

  if v_method = 'cash' then
    v_cash_account_code := '1010';
  else
    v_cash_account_code := '1020';
  end if;

  for r in
    select
      prl.employee_id,
      greatest(0, coalesce(prl.net, 0)) as net_base,
      nullif(upper(coalesce(prl.currency_code, '')), '') as currency_code,
      nullif(coalesce(prl.fx_rate, 0), 0) as fx_rate,
      nullif(coalesce(prl.foreign_amount, 0), 0) as foreign_amount
    from public.payroll_run_lines prl
    where prl.run_id = p_run_id
    order by prl.created_at asc
  loop
    if coalesce(r.net_base, 0) <= v_tol then
      continue;
    end if;

    v_party_id := public.ensure_financial_party_for_employee(r.employee_id);
    if v_party_id is null then
      continue;
    end if;

    insert into public.payroll_run_party_settlements(run_id, employee_id, party_id, currency_code, created_by, updated_by)
    values (p_run_id, r.employee_id, v_party_id, r.currency_code, auth.uid(), auth.uid())
    on conflict (run_id, employee_id) do update
      set party_id = excluded.party_id,
          currency_code = excluded.currency_code,
          updated_at = now(),
          updated_by = auth.uid();

    select s.payable_doc_id
    into v_doc_id
    from public.payroll_run_party_settlements s
    where s.run_id = p_run_id and s.employee_id = r.employee_id;

    if v_doc_id is null then
      v_currency := upper(coalesce(r.currency_code, v_base));
      v_fx := case
        when v_currency <> v_base and coalesce(r.fx_rate, 0) > 0 then r.fx_rate
        when v_currency <> v_base and coalesce(r.foreign_amount, 0) > 0 then (r.net_base / r.foreign_amount)
        else null
      end;

      v_doc_id := public.create_party_document(
        'ap_bill',
        v_occurred,
        v_party_id,
        concat('Payroll ', v_run.period_ym, ' allocation ', p_run_id::text, ' ', r.employee_id::text),
        jsonb_build_array(
          jsonb_strip_nulls(jsonb_build_object(
            'accountCode', v_payable_account_code,
            'debit', public._money_round(r.net_base, v_currency),
            'credit', 0,
            'memo', 'Payroll payable allocation',
            'currencyCode', case when v_currency <> v_base then v_currency else null end,
            'fxRate', v_fx,
            'foreignAmount', case when v_currency <> v_base then nullif(coalesce(r.foreign_amount,0),0) else null end
          )),
          jsonb_strip_nulls(jsonb_build_object(
            'accountCode', v_payable_account_code,
            'debit', 0,
            'credit', public._money_round(r.net_base, v_currency),
            'memo', 'Payroll payable to employee',
            'partyId', v_party_id::text,
            'currencyCode', case when v_currency <> v_base then v_currency else null end,
            'fxRate', v_fx,
            'foreignAmount', case when v_currency <> v_base then nullif(coalesce(r.foreign_amount,0),0) else null end
          ))
        ),
        null
      );

      if v_can_approve then
        perform public.approve_party_document(v_doc_id);
      else
        v_needs_approval := true;
      end if;

      update public.payroll_run_party_settlements
      set payable_doc_id = v_doc_id,
          updated_at = now(),
          updated_by = auth.uid()
      where run_id = p_run_id and employee_id = r.employee_id;

      v_created_payables := v_created_payables + 1;
    end if;
  end loop;

  if v_apply_advances then
    for r in
      select s.run_id, s.employee_id, s.party_id, s.payable_doc_id, s.payable_advance_settlement_id
      from public.payroll_run_party_settlements s
      where s.run_id = p_run_id
        and s.payable_doc_id is not null
    loop
      if r.payable_advance_settlement_id is not null then
        continue;
      end if;

      select *
      into v_payable_item
      from public.party_open_items poi
      where poi.party_document_id = r.payable_doc_id
        and poi.account_id = v_payable_account_id
        and poi.direction = 'credit'
        and poi.status <> 'settled'
      limit 1;

      if not found then
        continue;
      end if;

      v_currency := upper(coalesce(v_payable_item.currency_code, v_base));
      v_rem_base := coalesce(v_payable_item.open_base_amount, 0);
      v_rem_foreign := coalesce(v_payable_item.open_foreign_amount, 0);
      v_allocs := '[]'::jsonb;

      if v_payable_item.open_foreign_amount is not null then
        while v_rem_foreign > v_tol loop
          select *
          into v_payment_item
          from public.party_open_items poi
          where poi.party_id = r.party_id
            and poi.account_id = v_adv_account_id
            and poi.direction = 'debit'
            and poi.status <> 'settled'
            and upper(coalesce(poi.currency_code, v_base)) = v_currency
            and poi.open_foreign_amount is not null
            and coalesce(poi.open_foreign_amount, 0) > v_tol
          order by poi.occurred_at asc, poi.created_at asc
          limit 1;

          if not found then
            exit;
          end if;

          v_alloc_foreign := least(v_rem_foreign, coalesce(v_payment_item.open_foreign_amount, 0));
          if v_alloc_foreign <= v_tol then
            exit;
          end if;

          v_allocs := v_allocs || jsonb_build_array(
            jsonb_build_object(
              'fromOpenItemId', v_payment_item.id::text,
              'toOpenItemId', v_payable_item.id::text,
              'allocatedForeignAmount', v_alloc_foreign
            )
          );
          v_rem_foreign := v_rem_foreign - v_alloc_foreign;
        end loop;
      else
        while v_rem_base > v_tol loop
          select *
          into v_payment_item
          from public.party_open_items poi
          where poi.party_id = r.party_id
            and poi.account_id = v_adv_account_id
            and poi.direction = 'debit'
            and poi.status <> 'settled'
            and upper(coalesce(poi.currency_code, v_base)) = v_currency
            and coalesce(poi.open_base_amount, 0) > v_tol
          order by poi.occurred_at asc, poi.created_at asc
          limit 1;

          if not found then
            exit;
          end if;

          v_alloc_base := least(v_rem_base, coalesce(v_payment_item.open_base_amount, 0));
          if v_alloc_base <= v_tol then
            exit;
          end if;

          v_allocs := v_allocs || jsonb_build_array(
            jsonb_build_object(
              'fromOpenItemId', v_payment_item.id::text,
              'toOpenItemId', v_payable_item.id::text,
              'allocatedBaseAmount', v_alloc_base
            )
          );
          v_rem_base := v_rem_base - v_alloc_base;
        end loop;
      end if;

      if jsonb_array_length(v_allocs) > 0 then
        v_settlement_id := public.create_settlement(r.party_id, v_occurred, v_allocs, 'payroll_apply_advances');
        update public.payroll_run_party_settlements
        set payable_advance_settlement_id = v_settlement_id,
            updated_at = now(),
            updated_by = auth.uid()
        where run_id = p_run_id and employee_id = r.employee_id;
        v_created_adv_settlements := v_created_adv_settlements + 1;
      end if;
    end loop;
  end if;

  if v_pay_remaining then
    for r in
      select s.run_id, s.employee_id, s.party_id, s.payable_doc_id, s.payout_doc_id
      from public.payroll_run_party_settlements s
      where s.run_id = p_run_id
        and s.payable_doc_id is not null
    loop
      if r.payout_doc_id is not null then
        continue;
      end if;

      select *
      into v_payable_item
      from public.party_open_items poi
      where poi.party_document_id = r.payable_doc_id
        and poi.account_id = v_payable_account_id
        and poi.direction = 'credit'
        and poi.status <> 'settled'
      limit 1;

      if not found then
        continue;
      end if;

      v_currency := upper(coalesce(v_payable_item.currency_code, v_base));
      v_payout_amount_base := coalesce(v_payable_item.open_base_amount, 0);
      v_payout_amount_foreign := coalesce(v_payable_item.open_foreign_amount, 0);

      if v_payout_amount_base <= v_tol then
        continue;
      end if;

      v_fx := case
        when v_payable_item.open_foreign_amount is not null and v_payout_amount_foreign > v_tol then public._open_item_effective_fx_rate(v_payout_amount_foreign, v_payout_amount_base)
        else null
      end;

      v_doc_id := public.create_party_document(
        'ap_payment',
        v_occurred,
        r.party_id,
        concat('Payroll ', v_run.period_ym, ' payout ', p_run_id::text, ' ', r.employee_id::text),
        jsonb_build_array(
          jsonb_strip_nulls(jsonb_build_object(
            'accountCode', v_payable_account_code,
            'debit', public._money_round(v_payout_amount_base, v_currency),
            'credit', 0,
            'memo', 'Payroll payout settle payable',
            'partyId', r.party_id::text,
            'currencyCode', case when v_currency <> v_base then v_currency else null end,
            'fxRate', v_fx,
            'foreignAmount', case when v_currency <> v_base then nullif(v_payout_amount_foreign,0) else null end
          )),
          jsonb_strip_nulls(jsonb_build_object(
            'accountCode', v_cash_account_code,
            'debit', 0,
            'credit', public._money_round(v_payout_amount_base, v_currency),
            'memo', concat('Payroll payout ', v_method),
            'currencyCode', case when v_currency <> v_base then v_currency else null end,
            'fxRate', v_fx,
            'foreignAmount', case when v_currency <> v_base then nullif(v_payout_amount_foreign,0) else null end
          ))
        ),
        null
      );

      if v_can_approve then
        perform public.approve_party_document(v_doc_id);
      else
        v_needs_approval := true;
      end if;

      select *
      into v_payment_item
      from public.party_open_items poi
      where poi.party_document_id = v_doc_id
        and poi.account_id = v_payable_account_id
        and poi.direction = 'debit'
        and poi.status <> 'settled'
      limit 1;

      if not found then
        continue;
      end if;

      v_allocs := '[]'::jsonb;
      if v_payable_item.open_foreign_amount is not null and v_payment_item.open_foreign_amount is not null then
        v_alloc_foreign := least(coalesce(v_payment_item.open_foreign_amount,0), coalesce(v_payable_item.open_foreign_amount,0));
        if v_alloc_foreign > v_tol then
          v_allocs := jsonb_build_array(jsonb_build_object(
            'fromOpenItemId', v_payment_item.id::text,
            'toOpenItemId', v_payable_item.id::text,
            'allocatedForeignAmount', v_alloc_foreign
          ));
        end if;
      else
        v_alloc_base := least(coalesce(v_payment_item.open_base_amount,0), coalesce(v_payable_item.open_base_amount,0));
        if v_alloc_base > v_tol then
          v_allocs := jsonb_build_array(jsonb_build_object(
            'fromOpenItemId', v_payment_item.id::text,
            'toOpenItemId', v_payable_item.id::text,
            'allocatedBaseAmount', v_alloc_base
          ));
        end if;
      end if;

      if jsonb_array_length(v_allocs) > 0 then
        v_settlement_id := public.create_settlement(r.party_id, v_occurred, v_allocs, 'payroll_payout_settlement');
        update public.payroll_run_party_settlements
        set payout_doc_id = v_doc_id,
            payout_settlement_id = v_settlement_id,
            updated_at = now(),
            updated_by = auth.uid()
        where run_id = p_run_id and employee_id = r.employee_id;
        v_created_payouts := v_created_payouts + 1;
        v_created_payout_settlements := v_created_payout_settlements + 1;
      else
        update public.payroll_run_party_settlements
        set payout_doc_id = v_doc_id,
            updated_at = now(),
            updated_by = auth.uid()
        where run_id = p_run_id and employee_id = r.employee_id;
        v_created_payouts := v_created_payouts + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'payablesCreated', v_created_payables,
    'advanceSettlementsCreated', v_created_adv_settlements,
    'payoutDocsCreated', v_created_payouts,
    'payoutSettlementsCreated', v_created_payout_settlements,
    'needsApproval', v_needs_approval
  );
end;
$$;

revoke all on function public.payroll_settle_run_employees_v1(uuid, timestamptz, text, boolean, boolean) from public;
grant execute on function public.payroll_settle_run_employees_v1(uuid, timestamptz, text, boolean, boolean) to authenticated;

notify pgrst, 'reload schema';
