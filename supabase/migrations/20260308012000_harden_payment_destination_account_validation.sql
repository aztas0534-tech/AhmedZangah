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
    if p_require_when_available and coalesce(p_reference_table, '') = 'orders' and v_eligible_count > 0 then
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

revoke all on function public.resolve_payment_destination_account(text, text, jsonb, boolean, text) from public;
grant execute on function public.resolve_payment_destination_account(text, text, jsonb, boolean, text) to authenticated;

create or replace function public.record_order_payment_v2(
  p_order_id uuid,
  p_amount numeric,
  p_method text,
  p_occurred_at timestamptz default null,
  p_idempotency_key text default null,
  p_currency text default null,
  p_data jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method text;
  v_occurred_at timestamptz;
  v_currency text;
  v_shift_id uuid;
  v_data jsonb;
  v_idempotency text;
  v_dest uuid;
begin
  if not public.can_manage_orders() then
    raise exception 'not allowed';
  end if;
  if p_amount <= 0 then
    raise exception 'amount must be positive';
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

  v_currency := nullif(trim(coalesce(p_currency, '')), '');
  if v_currency is null then
    v_currency := public.get_base_currency();
  end if;
  v_currency := upper(v_currency);

  v_shift_id := public._resolve_open_shift_for_cash(auth.uid());
  if v_method = 'cash' and v_shift_id is null then
    raise exception 'cash payment requires an open shift';
  end if;

  v_data := jsonb_strip_nulls(jsonb_build_object('orderId', p_order_id::text) || coalesce(p_data, '{}'::jsonb));
  v_dest := public.resolve_payment_destination_account(v_method, v_currency, v_data, true, 'orders');
  if v_dest is null then
    v_data := v_data - 'destinationAccountId';
  else
    v_data := jsonb_set(v_data, '{destinationAccountId}', to_jsonb(v_dest::text), true);
  end if;

  v_idempotency := nullif(trim(coalesce(p_idempotency_key, '')), '');

  insert into public.payments(direction, method, amount, currency, reference_table, reference_id, occurred_at, created_by, data, idempotency_key, shift_id)
  values (
    'in',
    v_method,
    p_amount,
    v_currency,
    'orders',
    p_order_id::text,
    v_occurred_at,
    auth.uid(),
    v_data,
    v_idempotency,
    v_shift_id
  )
  on conflict (reference_table, reference_id, direction, idempotency_key)
  do update set
    method = excluded.method,
    amount = excluded.amount,
    currency = excluded.currency,
    occurred_at = excluded.occurred_at,
    created_by = excluded.created_by,
    data = excluded.data,
    shift_id = excluded.shift_id;
end;
$$;

revoke all on function public.record_order_payment_v2(uuid, numeric, text, timestamptz, text, text, jsonb) from public;
grant execute on function public.record_order_payment_v2(uuid, numeric, text, timestamptz, text, text, jsonb) to anon, authenticated;

create or replace function public.trg_validate_payment_destination_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dest uuid;
begin
  if new.data is null then
    new.data := '{}'::jsonb;
  end if;

  v_dest := public.resolve_payment_destination_account(
    new.method,
    new.currency,
    new.data,
    true,
    new.reference_table
  );

  if v_dest is null then
    new.data := new.data - 'destinationAccountId';
  else
    new.data := jsonb_set(new.data, '{destinationAccountId}', to_jsonb(v_dest::text), true);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_payment_destination_account on public.payments;
create trigger trg_validate_payment_destination_account
before insert or update of method, currency, data, reference_table
on public.payments
for each row
execute function public.trg_validate_payment_destination_account();

update public.payments p
set data = coalesce(p.data, '{}'::jsonb) - 'destinationAccountId'
where coalesce(p.data, '{}'::jsonb) ? 'destinationAccountId'
  and (
    btrim(coalesce(p.data->>'destinationAccountId', '')) = ''
    or not (
      btrim(coalesce(p.data->>'destinationAccountId', ''))
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    )
  );

notify pgrst, 'reload schema';
