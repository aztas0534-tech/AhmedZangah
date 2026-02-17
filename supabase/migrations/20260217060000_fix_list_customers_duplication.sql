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
    -- Fix: Exclude duplicates. If fp is linked to a customer, that customer is already returned above.
    and (fp.linked_entity_type is null or fp.linked_entity_type != 'customers')
  order by source asc, full_name asc
  limit greatest(coalesce(p_limit, 0), 0);
end;
$$;

revoke all on function public.list_customers_directory(integer) from public;
revoke execute on function public.list_customers_directory(integer) from anon;
grant execute on function public.list_customers_directory(integer) to authenticated;

notify pgrst, 'reload schema';
