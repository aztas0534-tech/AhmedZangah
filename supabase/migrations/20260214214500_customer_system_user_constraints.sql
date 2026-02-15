do $$
begin
  if to_regclass('public.customers') is null then
    return;
  end if;
end $$;

do $$
begin
  drop trigger if exists trg_customers_guard_system_user on public.customers;
exception when others then
  null;
end $$;

drop function if exists public.trg_customers_guard_system_user();

create or replace function public.trg_customers_reject_admin_users()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  v_id := coalesce(new.auth_user_id, old.auth_user_id);
  if v_id is null then
    return new;
  end if;

  if exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = v_id
      and au.is_active = true
  ) then
    raise exception 'ADMIN_USER_CANNOT_BE_CUSTOMER'
      using errcode = '42501',
            detail = 'auth_user_id exists in admin_users',
            hint = 'System users must not be inserted into public.customers.';
  end if;

  return new;
end;
$$;

do $$
begin
  drop trigger if exists trg_customers_reject_admin_users on public.customers;
  create constraint trigger trg_customers_reject_admin_users
  after insert or update of auth_user_id on public.customers
  deferrable initially immediate
  for each row execute function public.trg_customers_reject_admin_users();
end $$;

update public.customers c
set is_system_user = true
where exists (
  select 1
  from public.admin_users au
  where au.auth_user_id = c.auth_user_id
    and au.is_active = true
);

create or replace function public.ensure_financial_party_for_customer(p_customer_auth_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party_id uuid;
  v_name text;
  v_currency text;
begin
  if p_customer_auth_user_id is null then
    return null;
  end if;

  if public.is_system_user(p_customer_auth_user_id) then
    return null;
  end if;

  select fpl.party_id
  into v_party_id
  from public.financial_party_links fpl
  where fpl.linked_entity_type = 'customers'
    and fpl.linked_entity_id = p_customer_auth_user_id::text
    and fpl.role = 'customer'
  limit 1;

  if v_party_id is not null then
    return v_party_id;
  end if;

  select
    coalesce(nullif(trim(c.full_name), ''), nullif(trim(c.email), ''), nullif(trim(c.phone_number), ''), p_customer_auth_user_id::text),
    nullif(trim(coalesce(c.preferred_currency, '')), '')
  into v_name, v_currency
  from public.customers c
  where c.auth_user_id = p_customer_auth_user_id;

  insert into public.financial_parties(name, party_type, linked_entity_type, linked_entity_id, currency_preference, created_by, updated_by)
  values (coalesce(v_name, p_customer_auth_user_id::text), 'customer', 'customers', p_customer_auth_user_id::text, v_currency, auth.uid(), auth.uid())
  returning id into v_party_id;

  insert into public.financial_party_links(party_id, role, linked_entity_type, linked_entity_id, created_by)
  values (v_party_id, 'customer', 'customers', p_customer_auth_user_id::text, auth.uid())
  on conflict (linked_entity_type, linked_entity_id, role) do nothing;

  return v_party_id;
end;
$$;

revoke all on function public.ensure_financial_party_for_customer(uuid) from public;
grant execute on function public.ensure_financial_party_for_customer(uuid) to authenticated;

create or replace view public.customers_business as
select c.*
from public.customers c
where not public.is_system_user(c.auth_user_id);

alter view public.customers_business set (security_invoker = true);
grant select on public.customers_business to authenticated;

notify pgrst, 'reload schema';
