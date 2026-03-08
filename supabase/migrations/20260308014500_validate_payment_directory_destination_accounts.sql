set app.allow_ledger_ddl = '1';

create or replace function public.trg_validate_payment_directory_destination_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data jsonb;
  v_raw text;
  v_dest uuid;
  v_parent_code text;
  v_ok boolean := false;
  v_is_active boolean := true;
begin
  v_data := coalesce(new.data, '{}'::jsonb);
  begin
    v_is_active := coalesce((v_data->>'isActive')::boolean, true);
  exception when others then
    v_is_active := true;
  end;

  if tg_table_name = 'banks' then
    v_parent_code := '1020';
  elsif tg_table_name = 'transfer_recipients' then
    v_parent_code := '1030';
  else
    return new;
  end if;

  v_raw := btrim(coalesce(v_data->>'destinationAccountId', ''));
  if v_raw = '' then
    if v_is_active then
      raise exception 'destinationAccountId is required for active % records', tg_table_name;
    end if;
    new.data := v_data - 'destinationAccountId';
    return new;
  end if;

  begin
    v_dest := v_raw::uuid;
  exception when others then
    raise exception 'invalid destinationAccountId format for %', tg_table_name;
  end;

  select exists (
    select 1
    from public.chart_of_accounts c
    join public.chart_of_accounts p on p.id = c.parent_id
    where c.id = v_dest
      and c.is_active = true
      and p.code = v_parent_code
  )
  into v_ok;

  if not v_ok then
    raise exception 'destinationAccountId is invalid for %', tg_table_name;
  end if;

  new.data := jsonb_set(v_data, '{destinationAccountId}', to_jsonb(v_dest::text), true);
  return new;
end;
$$;

drop trigger if exists trg_validate_payment_directory_destination_account on public.banks;
create trigger trg_validate_payment_directory_destination_account
before insert or update of data on public.banks
for each row
execute function public.trg_validate_payment_directory_destination_account();

drop trigger if exists trg_validate_payment_directory_destination_account on public.transfer_recipients;
create trigger trg_validate_payment_directory_destination_account
before insert or update of data on public.transfer_recipients
for each row
execute function public.trg_validate_payment_directory_destination_account();

update public.banks b
set data = jsonb_set(
  coalesce(b.data, '{}'::jsonb),
  '{isActive}',
  'false'::jsonb,
  true
)
where (
  case
    when lower(coalesce(coalesce(b.data, '{}'::jsonb)->>'isActive', 'true')) in ('false', 'f', '0', 'no', 'off') then false
    else true
  end
) = true
  and btrim(coalesce(coalesce(b.data, '{}'::jsonb)->>'destinationAccountId', '')) = '';

update public.transfer_recipients r
set data = jsonb_set(
  coalesce(r.data, '{}'::jsonb),
  '{isActive}',
  'false'::jsonb,
  true
)
where (
  case
    when lower(coalesce(coalesce(r.data, '{}'::jsonb)->>'isActive', 'true')) in ('false', 'f', '0', 'no', 'off') then false
    else true
  end
) = true
  and btrim(coalesce(coalesce(r.data, '{}'::jsonb)->>'destinationAccountId', '')) = '';

notify pgrst, 'reload schema';
