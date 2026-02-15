do $$
begin
  if to_regclass('private.keys') is not null then
    if not exists (
      select 1
      from private.keys
      where key_name = 'app.encryption_key'
    ) then
      insert into private.keys(key_name, key_value)
      values ('app.encryption_key', concat('dev-', gen_random_uuid()::text, gen_random_uuid()::text));
    end if;
  end if;
end $$;

do $$
declare
  v_default_id uuid := '00000000-0000-4000-8000-000000000001'::uuid;
begin
  if to_regclass('public.journals') is null then
    return;
  end if;
  if not exists (select 1 from public.journals where id = v_default_id) then
    insert into public.journals(id, code, name, is_default, is_active)
    values (v_default_id, 'GEN', 'دفتر اليومية العام', true, true)
    on conflict (code) do update
    set name = excluded.name,
        is_active = true;
  end if;
  update public.journals
  set is_default = (id = v_default_id)
  where is_default = true or id = v_default_id;
exception when others then
  null;
end $$;

do $$
declare
  v_company uuid;
  v_branch uuid;
  v_wh uuid;
begin
  if to_regclass('public.warehouses') is null then
    return;
  end if;

  select id into v_company from public.companies order by created_at asc limit 1;
  select id into v_branch from public.branches order by created_at asc limit 1;

  select id into v_wh from public.warehouses where is_active = true order by created_at asc limit 1;
  if v_wh is null then
    insert into public.warehouses(code, name, type, is_active, company_id, branch_id, pricing)
    values ('MAIN', 'المخزن الرئيسي', 'main', true, v_company, v_branch, '{}'::jsonb)
    returning id into v_wh;
  end if;

  if to_regclass('public.admin_users') is not null and v_wh is not null then
    update public.admin_users
    set warehouse_id = v_wh
    where warehouse_id is null
      and is_active = true
      and role in ('owner','manager');
  end if;
end $$;
