set app.allow_ledger_ddl = '1';

create or replace function public.resolve_payment_destination_account(
  p_method text,
  p_currency text,
  p_data jsonb default '{}'::jsonb,
  p_require_when_available boolean default false,
  p_reference_table text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method text;
  v_currency text;
  v_parent_code text;
  v_raw text;
  v_dest uuid;
  v_eligible_count integer := 0;
  v_ok boolean := false;
begin
  v_method := lower(nullif(btrim(coalesce(p_method, '')), ''));
  if v_method is null then
    v_method := 'cash';
  end if;
  if v_method = 'card' then
    v_method := 'network';
  elsif v_method = 'bank' then
    v_method := 'kuraimi';
  end if;
  if v_method not in ('kuraimi', 'network') then
    return null;
  end if;

  v_parent_code := case when v_method = 'kuraimi' then '1020' else '1030' end;
  v_currency := upper(nullif(btrim(coalesce(p_currency, public.get_base_currency())), ''));
  if v_currency is null then
    v_currency := public.get_base_currency();
  end if;

  select count(*)
  into v_eligible_count
  from public.chart_of_accounts c
  join public.chart_of_accounts p on p.id = c.parent_id
  where c.is_active = true
    and p.code = v_parent_code
    and upper(coalesce(substring(c.code from '([A-Za-z]{3})$'), '')) = v_currency;

  v_raw := btrim(coalesce(coalesce(p_data, '{}'::jsonb)->>'destinationAccountId', ''));
  if v_raw = '' then
    if p_require_when_available
       and coalesce(p_reference_table, '') in ('orders', 'purchase_orders', 'expenses')
       and v_eligible_count > 0 then
      raise exception 'destinationAccountId is required for % payments in currency %', v_method, v_currency;
    end if;
    return null;
  end if;

  begin
    v_dest := v_raw::uuid;
  exception when others then
    raise exception 'invalid destinationAccountId format';
  end;

  select exists (
    select 1
    from public.chart_of_accounts c
    join public.chart_of_accounts p on p.id = c.parent_id
    where c.id = v_dest
      and c.is_active = true
      and p.code = v_parent_code
      and upper(coalesce(substring(c.code from '([A-Za-z]{3})$'), '')) = v_currency
  )
  into v_ok;

  if not v_ok then
    raise exception 'destinationAccountId is invalid for payment method/currency';
  end if;
  return v_dest;
end;
$$;

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
  v_amount numeric;
  v_total numeric;
  v_status text;
  v_method text;
  v_occurred_at timestamptz;
  v_data jsonb;
  v_override text;
  v_destination text;
begin
  if not public.can_manage_stock() then
    raise exception 'not allowed';
  end if;
  if p_expense_id is null then
    raise exception 'p_expense_id is required';
  end if;

  select coalesce(e.amount, 0), e.status
  into v_total, v_status
  from public.expenses e
  where e.id = p_expense_id
  for update;
  if not found then
    raise exception 'expense not found';
  end if;
  if v_status = 'cancelled' then
    raise exception 'cannot pay cancelled expense';
  end if;
  if v_total <= 0 then
    raise exception 'expense amount is zero';
  end if;
  v_amount := coalesce(p_amount, 0);
  if v_amount <= 0 then
    raise exception 'invalid amount';
  end if;
  if v_amount > (v_total + 0.000000001) then
    raise exception 'paid amount exceeds expense total';
  end if;

  v_method := nullif(trim(coalesce(p_method, '')), '');
  if v_method is null then
    v_method := 'cash';
  end if;
  v_occurred_at := coalesce(p_occurred_at, now());

  select nullif(trim(coalesce(e.data->>'overrideAccountId', '')), '')
  into v_override
  from public.expenses e
  where e.id = p_expense_id;

  select nullif(trim(coalesce(e.data->>'destinationAccountId', '')), '')
  into v_destination
  from public.expenses e
  where e.id = p_expense_id;

  v_data := jsonb_strip_nulls(jsonb_build_object(
    'expenseId', p_expense_id::text,
    'overrideAccountId', v_override,
    'destinationAccountId', v_destination
  ));

  insert into public.payments(direction, method, amount, currency, reference_table, reference_id, occurred_at, created_by, data)
  values (
    'out',
    v_method,
    v_amount,
    (
      select upper(coalesce(nullif(btrim(e.currency), ''), public.get_base_currency()))
      from public.expenses e
      where e.id = p_expense_id
    ),
    'expenses',
    p_expense_id::text,
    v_occurred_at,
    auth.uid(),
    v_data
  );
end;
$$;

notify pgrst, 'reload schema';
