set client_min_messages = notice;
set statement_timeout = 0;
set lock_timeout = 0;

do $$
declare
  v_admin uuid;
begin
  select u.id into v_admin
  from auth.users u
  where lower(u.email) = lower('smoke-admin@local.test')
  limit 1;

  if v_admin is null then
    v_admin := gen_random_uuid();
    insert into auth.users(id, email, aud, role, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous, created_at, updated_at)
    values (v_admin, 'smoke-admin@local.test', 'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb, false, false, now(), now());
  end if;

  insert into public.admin_users(auth_user_id, username, full_name, email, role, permissions, is_active)
  values (v_admin, 'smoke-admin', 'Smoke Admin', 'smoke-admin@local.test', 'manager', array[]::text[], true)
  on conflict (auth_user_id) do update
  set username = excluded.username,
      full_name = excluded.full_name,
      email = excluded.email,
      role = excluded.role,
      permissions = excluded.permissions,
      is_active = excluded.is_active,
      updated_at = now();

  perform set_config('app.smoke_admin_id', v_admin::text, false);
end $$;

do $$
declare
  t0 timestamptz;
  ms int;
  v_admin_id uuid;
begin
  t0 := clock_timestamp();
  if to_regclass('public.customers') is null then raise exception 'customers missing'; end if;
  if to_regclass('public.admin_users') is null then raise exception 'admin_users missing'; end if;
  if to_regclass('public.financial_parties') is null then raise exception 'financial_parties missing'; end if;
  if to_regclass('public.financial_party_links') is null then raise exception 'financial_party_links missing'; end if;
  if to_regprocedure('public.list_customers_directory(integer)') is null then raise exception 'list_customers_directory missing'; end if;
  if to_regprocedure('public.is_system_user(uuid)') is null then raise exception 'is_system_user missing'; end if;
  if to_regclass('public.customers_business') is null then raise exception 'customers_business view missing'; end if;
  if not exists (
    select 1
    from pg_trigger t
    where t.tgname = 'trg_customers_reject_admin_users'
  ) then
    raise exception 'constraint trigger trg_customers_reject_admin_users missing';
  end if;

  v_admin_id := nullif(current_setting('app.smoke_admin_id', true), '')::uuid;
  if v_admin_id is null then raise exception 'missing app.smoke_admin_id'; end if;
  if public.is_system_user(v_admin_id) is distinct from true then
    raise exception 'expected is_system_user(smoke admin) = true';
  end if;

  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  raise notice 'SMOKE_PASS|RG00|Schema objects exist|%|{}', ms;
end $$;

set role postgres;
do $$
declare
  t0 timestamptz;
  ms int;
  v_admin_id uuid;
  v_admin_id_text text;
begin
  t0 := clock_timestamp();
  v_admin_id_text := nullif(current_setting('app.smoke_admin_id', true), '');
  if v_admin_id_text is null then raise exception 'missing app.smoke_admin_id'; end if;
  v_admin_id := v_admin_id_text::uuid;

  begin
    insert into public.customers(auth_user_id, full_name, phone_number, email, auth_provider, data)
    values (v_admin_id, 'Admin As Customer', '799999999', 'admin-as-customer@smoke.local', 'password', '{}'::jsonb);
    raise exception 'expected admin customer insert to fail';
  exception when others then
    if position('ADMIN_USER_CANNOT_BE_CUSTOMER' in coalesce(sqlerrm, '')) = 0 then
      raise;
    end if;
  end;

  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  raise notice 'SMOKE_PASS|RG01|Admin cannot be inserted into customers|%|{}', ms;
end $$;

set role postgres;
do $$
declare
  v_id uuid;
begin
  select u.id into v_id
  from auth.users u
  where lower(u.email) = lower('smoke-customer@local.test')
  limit 1;

  if v_id is null then
    v_id := gen_random_uuid();
    insert into auth.users(id, email, aud, role, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous, created_at, updated_at)
    values (v_id, 'smoke-customer@local.test', 'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb, false, false, now(), now());
  end if;

  perform set_config('app.smoke_customer_id', v_id::text, false);
end $$;
set role authenticated;

do $$
declare
  t0 timestamptz;
  ms int;
  v_id uuid;
  v_party uuid;
  v_cnt int;
  v_admin_id uuid;
begin
  t0 := clock_timestamp();

  v_id := nullif(current_setting('app.smoke_customer_id', true), '')::uuid;
  if v_id is null then raise exception 'missing app.smoke_customer_id'; end if;
  v_admin_id := nullif(current_setting('app.smoke_admin_id', true), '')::uuid;
  if v_admin_id is null then raise exception 'missing app.smoke_admin_id'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_id::text, 'role', 'authenticated')::text, false);
  set role authenticated;

  begin
    insert into public.customers(auth_user_id, full_name, phone_number, email, auth_provider, data)
    values (v_id, 'Smoke Customer', '777000111', 'smoke-customer@local.test', 'password', '{}'::jsonb);
  exception when unique_violation then
    update public.customers
    set full_name = 'Smoke Customer',
        phone_number = '777000111',
        email = 'smoke-customer@local.test',
        auth_provider = 'password'
    where auth_user_id = v_id;
  end;

  select count(*) into v_cnt
  from public.customers_business c
  where c.auth_user_id = v_id;
  if v_cnt <> 1 then
    raise exception 'expected customers_business to include smoke customer';
  end if;

  select count(*) into v_cnt
  from public.customers_business c
  where c.auth_user_id = v_admin_id;
  if v_cnt <> 0 then
    raise exception 'expected customers_business to exclude smoke admin';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, false);
  set role authenticated;

  select fpl.party_id into v_party
  from public.financial_party_links fpl
  where fpl.linked_entity_type = 'customers'
    and fpl.linked_entity_id = v_id::text
    and fpl.role = 'customer'
  limit 1;
  if v_party is null then
    raise exception 'expected customer financial party link to exist';
  end if;

  select count(*) into v_cnt
  from public.list_customers_directory(2000) x
  where x.id = v_admin_id::text;
  if v_cnt <> 0 then
    raise exception 'expected directory to exclude smoke admin';
  end if;

  select count(*) into v_cnt
  from public.list_customers_directory(2000) x
  where x.id = v_id::text;
  if v_cnt <> 1 then
    raise exception 'expected directory to include smoke customer';
  end if;

  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  raise notice 'SMOKE_PASS|RG02|Business customer flows and directory|%|{}', ms;
end $$;

do $$
declare
  t0 timestamptz;
  ms int;
begin
  t0 := clock_timestamp();
  if to_regprocedure('public.get_fx_rate_rpc(text)') is null then
    raise exception 'get_fx_rate_rpc missing';
  end if;
  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  raise notice 'SMOKE_PASS|RG03|Key RPCs exist|%|{}', ms;
end $$;

\echo REGRESSION_V2_OK
