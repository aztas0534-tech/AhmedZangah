alter table public.customers
add column if not exists is_system_user boolean not null default false;

create index if not exists idx_customers_is_system_user
on public.customers(is_system_user);

create or replace function public.is_system_user(p_auth_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1
    from public.admin_users au
    where au.auth_user_id = p_auth_user_id
      and au.is_active = true
  );
$$;
revoke all on function public.is_system_user(uuid) from public;
grant execute on function public.is_system_user(uuid) to authenticated;

create or replace function public.trg_customers_guard_system_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if public.is_system_user(new.auth_user_id) then
      new.is_system_user := true;
      return null;
    end if;
    new.is_system_user := false;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if public.is_system_user(coalesce(new.auth_user_id, old.auth_user_id)) then
      new.is_system_user := true;
      return new;
    end if;
    if coalesce(old.is_system_user, false) and not coalesce(new.is_system_user, false) then
      raise exception 'system_user_flag_cannot_be_cleared';
    end if;
    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_customers_guard_system_user on public.customers;
create trigger trg_customers_guard_system_user
before insert or update on public.customers
for each row execute function public.trg_customers_guard_system_user();

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
  v_is_sys boolean := false;
begin
  if p_customer_auth_user_id is null then
    return null;
  end if;

  if public.is_system_user(p_customer_auth_user_id) then
    return null;
  end if;

  begin
    select coalesce(c.is_system_user, false)
    into v_is_sys
    from public.customers c
    where c.auth_user_id = p_customer_auth_user_id;
  exception when others then
    v_is_sys := false;
  end;

  if v_is_sys then
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
where coalesce(c.is_system_user, false) = false
  and not exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = c.auth_user_id
      and au.is_active = true
  );

alter view public.customers_business set (security_invoker = true);
grant select on public.customers_business to authenticated;

create or replace function public.list_customers_directory(p_limit integer default 1000)
returns table (
  id text,
  full_name text,
  phone_number text,
  email text,
  auth_provider text,
  password_salt text,
  password_hash text,
  referral_code text,
  referred_by text,
  loyalty_points integer,
  loyalty_tier text,
  total_spent numeric,
  first_order_discount_applied boolean,
  avatar_url text,
  preferred_currency text,
  data jsonb,
  source text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_permission('customers.manage') then
    raise exception 'not allowed';
  end if;

  return query
  select
    c.auth_user_id::text as id,
    c.full_name,
    c.phone_number,
    c.email,
    c.auth_provider,
    c.password_salt,
    c.password_hash,
    c.referral_code,
    c.referred_by,
    c.loyalty_points,
    c.loyalty_tier,
    c.total_spent,
    c.first_order_discount_applied,
    c.avatar_url,
    c.preferred_currency,
    c.data,
    'customers'::text as source
  from public.customers_business c
  union all
  select
    fp.id::text as id,
    fp.name as full_name,
    null::text as phone_number,
    null::text as email,
    'password'::text as auth_provider,
    null::text as password_salt,
    null::text as password_hash,
    null::text as referral_code,
    null::text as referred_by,
    0::integer as loyalty_points,
    'regular'::text as loyalty_tier,
    0::numeric as total_spent,
    false as first_order_discount_applied,
    null::text as avatar_url,
    fp.currency_preference as preferred_currency,
    '{}'::jsonb as data,
    'financial_parties'::text as source
  from public.financial_parties fp
  where fp.party_type = 'customer'
    and fp.is_active = true
    and not (
      fp.linked_entity_type = 'customers'
      and public.is_system_user(public._uuid_or_null(fp.linked_entity_id))
    )
  order by source asc, full_name asc
  limit greatest(coalesce(p_limit, 0), 0);
end;
$$;
revoke all on function public.list_customers_directory(integer) from public;
revoke execute on function public.list_customers_directory(integer) from anon;
grant execute on function public.list_customers_directory(integer) to authenticated;

notify pgrst, 'reload schema';
