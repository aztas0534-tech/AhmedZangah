set app.allow_ledger_ddl = '1';

do $$
declare
  v_base text;
begin
  if to_regclass('public.expenses') is not null then
    begin
      alter table public.expenses add column currency text;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.expenses add column fx_rate numeric;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.expenses add column base_amount numeric generated always as (coalesce(amount, 0) * coalesce(fx_rate, 1)) stored;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.expenses add column fx_locked boolean default true;
    exception when duplicate_column then null;
    end;
    begin
      alter table public.expenses add column cost_center_id uuid references public.cost_centers(id) on delete set null;
    exception
      when duplicate_column then null;
      when undefined_table then null;
    end;
    begin
      alter table public.expenses add column data jsonb not null default '{}'::jsonb;
    exception when duplicate_column then null;
    end;

    v_base := public.get_base_currency();

    update public.expenses e
    set currency = coalesce(nullif(btrim(upper(e.currency)), ''), v_base),
        fx_rate = coalesce(
          e.fx_rate,
          case
            when upper(coalesce(e.currency, v_base)) = upper(v_base) then 1
            else public.get_fx_rate(upper(coalesce(e.currency, v_base)), e.date, 'operational')
          end
        ),
        fx_locked = coalesce(e.fx_locked, true)
    where e.currency is null or e.fx_rate is null or e.fx_locked is null;

    begin
      alter table public.expenses add constraint expenses_currency_check check (currency is not null);
    exception when duplicate_object then null;
    end;
    begin
      alter table public.expenses add constraint expenses_fx_rate_check check (fx_rate is not null and fx_rate > 0);
    exception when duplicate_object then null;
    end;
  end if;
end $$;

create or replace function public.trg_set_expense_fx()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
  v_rate numeric;
  v_date date;
begin
  v_base := public.get_base_currency();
  if new.currency is null then
    new.currency := v_base;
  end if;
  new.currency := upper(nullif(btrim(coalesce(new.currency, v_base)), ''));
  if new.currency is null then
    new.currency := v_base;
  end if;

  v_date := coalesce(new.date, current_date);

  if new.fx_rate is null then
    if v_base is not null and new.currency = upper(v_base) then
      new.fx_rate := 1;
    else
      v_rate := public.get_fx_rate(new.currency, v_date, 'operational');
      if v_rate is null or v_rate <= 0 then
        raise exception 'fx rate missing for currency %', new.currency;
      end if;
      new.fx_rate := v_rate;
    end if;
  end if;

  if tg_op = 'UPDATE' and coalesce(old.fx_locked, true) then
    if new.currency is distinct from old.currency or new.fx_rate is distinct from old.fx_rate then
      raise exception 'fx locked: cannot change currency/fx_rate';
    end if;
  end if;

  return new;
end;
$$;

do $$
begin
  if to_regclass('public.expenses') is not null then
    drop trigger if exists trg_set_expense_fx on public.expenses;
    create trigger trg_set_expense_fx
    before insert or update on public.expenses
    for each row execute function public.trg_set_expense_fx();
  end if;
end $$;

create or replace function public.record_expense_payment(
  p_expense_id uuid,
  p_amount numeric,
  p_method text,
  p_occurred_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method text;
  v_occurred_at timestamptz;
  v_shift_id uuid;
  v_data jsonb := '{}'::jsonb;
  v_override text;
  v_currency text;
  v_fx numeric;
  v_amount numeric;
begin
  if not public.can_manage_expenses() then
    raise exception 'not allowed';
  end if;

  if p_expense_id is null then
    raise exception 'p_expense_id is required';
  end if;

  v_amount := coalesce(p_amount, 0);
  if v_amount <= 0 then
    select coalesce(e.amount, 0) into v_amount from public.expenses e where e.id = p_expense_id;
  end if;
  if v_amount <= 0 then
    raise exception 'amount must be positive';
  end if;

  select
    upper(nullif(btrim(coalesce(e.currency, public.get_base_currency())), '')),
    coalesce(e.fx_rate, 1),
    nullif(trim(coalesce(e.data->>'overrideAccountId', '')), '')
  into v_currency, v_fx, v_override
  from public.expenses e
  where e.id = p_expense_id;

  if v_currency is null then
    v_currency := upper(nullif(btrim(coalesce(public.get_base_currency(), '')), ''));
  end if;
  if v_currency is null then
    raise exception 'currency missing';
  end if;
  if coalesce(v_fx, 0) <= 0 then
    v_fx := 1;
  end if;

  v_method := nullif(trim(p_method), '');
  if v_method is null then
    v_method := 'cash';
  end if;
  if v_method = 'card' then
    v_method := 'network';
  elsif v_method = 'bank' then
    v_method := 'kuraimi';
  end if;

  v_occurred_at := coalesce(p_occurred_at, now());
  v_shift_id := public._resolve_open_shift_for_cash(auth.uid());
  if v_method = 'cash' and v_shift_id is null then
    raise exception 'cash payment requires an open shift';
  end if;

  v_data := jsonb_strip_nulls(jsonb_build_object('expenseId', p_expense_id::text, 'overrideAccountId', v_override));

  insert into public.payments(direction, method, amount, currency, fx_rate, reference_table, reference_id, occurred_at, created_by, shift_id, data)
  values (
    'out',
    v_method,
    v_amount,
    v_currency,
    v_fx,
    'expenses',
    p_expense_id::text,
    v_occurred_at,
    auth.uid(),
    v_shift_id,
    v_data
  );
end;
$$;

revoke all on function public.record_expense_payment(uuid, numeric, text, timestamptz) from public;
grant execute on function public.record_expense_payment(uuid, numeric, text, timestamptz) to anon, authenticated;

create or replace function public.record_expense_accrual(
  p_expense_id uuid,
  p_amount numeric,
  p_occurred_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_id uuid;
  v_expenses uuid;
  v_ap uuid;
  v_override text;
  v_currency text;
  v_fx numeric;
  v_amount_foreign numeric;
  v_amount_base numeric;
  v_exp_date date;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;

  if p_expense_id is null then
    raise exception 'p_expense_id is required';
  end if;

  v_amount_foreign := coalesce(p_amount, 0);
  if v_amount_foreign <= 0 then
    select coalesce(e.amount, 0) into v_amount_foreign from public.expenses e where e.id = p_expense_id;
  end if;
  if v_amount_foreign <= 0 then
    raise exception 'amount must be positive';
  end if;

  v_expenses := public.get_account_id_by_code('6100');
  v_ap := public.get_account_id_by_code('2010');
  if v_expenses is null or v_ap is null then
    raise exception 'required accounts not found';
  end if;

  select
    upper(nullif(btrim(coalesce(e.currency, public.get_base_currency())), '')),
    coalesce(e.fx_rate, 1),
    e.date,
    nullif(trim(coalesce(e.data->>'overrideAccountId','')), '')
  into v_currency, v_fx, v_exp_date, v_override
  from public.expenses e
  where e.id = p_expense_id;

  if v_currency is null then
    v_currency := upper(nullif(btrim(coalesce(public.get_base_currency(), '')), ''));
  end if;

  if coalesce(v_fx, 0) <= 0 then
    if v_currency is not null and v_currency = upper(public.get_base_currency()) then
      v_fx := 1;
    else
      v_fx := public.get_fx_rate(v_currency, coalesce(v_exp_date, current_date), 'operational');
    end if;
  end if;

  if coalesce(v_fx, 0) <= 0 then
    raise exception 'fx rate missing for currency %', coalesce(v_currency, '');
  end if;

  v_amount_base := v_amount_foreign * v_fx;

  v_ap := public.resolve_override_account(v_ap, v_override, array['liability','equity']);

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by)
  values (
    coalesce(p_occurred_at, now()),
    concat('Expense accrual: ', p_expense_id),
    'expenses',
    p_expense_id::text,
    'accrual',
    auth.uid()
  )
  returning id into v_entry_id;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values
    (v_entry_id, v_expenses, v_amount_base, 0, 'Expense accrual'),
    (v_entry_id, v_ap, 0, v_amount_base, 'Expense payable');

  perform public.check_journal_entry_balance(v_entry_id);
end;
$$;

revoke all on function public.record_expense_accrual(uuid, numeric, timestamptz) from public;
grant execute on function public.record_expense_accrual(uuid, numeric, timestamptz) to anon, authenticated;

notify pgrst, 'reload schema';
