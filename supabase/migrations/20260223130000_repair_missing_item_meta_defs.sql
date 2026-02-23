create or replace function public.repair_missing_item_meta_defs(p_dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now text := now()::text;
  v_missing_cat text[] := array[]::text[];
  v_missing_unit text[] := array[]::text[];
  v_missing_group text[] := array[]::text[];
  v_ins_cat int := 0;
  v_ins_unit int := 0;
  v_ins_group int := 0;
begin
  if auth.role() <> 'service_role' then
    if not public.is_admin() then
      raise exception 'not allowed';
    end if;
  end if;

  if to_regclass('public.menu_items') is null then
    raise exception 'menu_items not found';
  end if;

  if to_regclass('public.item_categories') is not null then
    select coalesce(array_agg(k order by k), array[]::text[])
    into v_missing_cat
    from (
      select distinct nullif(btrim(coalesce(mi.category, '')), '') as k
      from public.menu_items mi
      where nullif(btrim(coalesce(mi.category, '')), '') is not null
        and not exists (select 1 from public.item_categories c where c.key = mi.category)
    ) x;

    if not p_dry_run then
      insert into public.item_categories(id, key, is_active, data)
      select
        gen_random_uuid(),
        k,
        true,
        jsonb_build_object(
          'id', gen_random_uuid()::text,
          'key', k,
          'name', jsonb_build_object(
            'ar', case
              when lower(k) in ('food','grocery') then 'مواد غذائية'
              when lower(k) like 'cat_%' then k
              else k
            end,
            'en', ''
          ),
          'isActive', true,
          'createdAt', v_now,
          'updatedAt', v_now
        )
      from unnest(v_missing_cat) as k
      on conflict (key) do nothing;
      get diagnostics v_ins_cat = row_count;
    end if;
  end if;

  if to_regclass('public.unit_types') is not null then
    select coalesce(array_agg(k order by k), array[]::text[])
    into v_missing_unit
    from (
      select distinct nullif(btrim(coalesce(mi.base_unit, mi.unit_type, mi.data->>'baseUnit', mi.data->>'unitType', '')), '') as k
      from public.menu_items mi
      where nullif(btrim(coalesce(mi.base_unit, mi.unit_type, mi.data->>'baseUnit', mi.data->>'unitType', '')), '') is not null
        and not exists (
          select 1 from public.unit_types u
          where u.key = nullif(btrim(coalesce(mi.base_unit, mi.unit_type, mi.data->>'baseUnit', mi.data->>'unitType', '')), '')
        )
    ) x;

    if not p_dry_run then
      insert into public.unit_types(id, key, is_active, is_weight_based, data)
      select
        gen_random_uuid(),
        k,
        true,
        (lower(k) in ('kg','gram')),
        jsonb_build_object(
          'id', gen_random_uuid()::text,
          'key', k,
          'label', jsonb_build_object(
            'ar', case
              when lower(k) = 'piece' then 'حبة'
              when lower(k) = 'kg' then 'كيلو'
              when lower(k) = 'gram' then 'جرام'
              when lower(k) = 'pack' then 'باك'
              when lower(k) = 'carton' then 'كرتون'
              else k
            end,
            'en', ''
          ),
          'isActive', true,
          'isWeightBased', (lower(k) in ('kg','gram')),
          'createdAt', v_now,
          'updatedAt', v_now
        )
      from unnest(v_missing_unit) as k
      on conflict (key) do nothing;
      get diagnostics v_ins_unit = row_count;
    end if;
  end if;

  if to_regclass('public.item_groups') is not null then
    with used_groups as (
      select
        nullif(btrim(coalesce(mi.data->>'group', mi.data->>'groupKey', mi.data->>'group_key', mi.data->>'groupId', '')), '') as gk,
        nullif(btrim(coalesce(mi.category, '')), '') as ck
      from public.menu_items mi
    ),
    missing as (
      select distinct ug.gk
      from used_groups ug
      where ug.gk is not null
        and not exists (
          select 1 from public.item_groups g
          where g.key = ug.gk
        )
    ),
    best_cat as (
      select
        m.gk,
        (
          select ug2.ck
          from used_groups ug2
          where ug2.gk = m.gk and ug2.ck is not null
          group by ug2.ck
          order by count(*) desc, ug2.ck asc
          limit 1
        ) as ck
      from missing m
    )
    select coalesce(array_agg(gk order by gk), array[]::text[])
    into v_missing_group
    from best_cat;

    if not p_dry_run then
      insert into public.item_groups(id, category_key, key, is_active, data)
      select
        gen_random_uuid(),
        coalesce(bc.ck, 'grocery'),
        bc.gk,
        true,
        jsonb_build_object(
          'id', gen_random_uuid()::text,
          'categoryKey', coalesce(bc.ck, 'grocery'),
          'key', bc.gk,
          'name', jsonb_build_object('ar', bc.gk, 'en', ''),
          'isActive', true,
          'createdAt', v_now,
          'updatedAt', v_now
        )
      from (
        with used_groups as (
          select
            nullif(btrim(coalesce(mi.data->>'group', mi.data->>'groupKey', mi.data->>'group_key', mi.data->>'groupId', '')), '') as gk,
            nullif(btrim(coalesce(mi.category, '')), '') as ck
          from public.menu_items mi
        ),
        missing as (
          select distinct ug.gk
          from used_groups ug
          where ug.gk is not null
            and not exists (select 1 from public.item_groups g where g.key = ug.gk)
        )
        select
          m.gk,
          (
            select ug2.ck
            from used_groups ug2
            where ug2.gk = m.gk and ug2.ck is not null
            group by ug2.ck
            order by count(*) desc, ug2.ck asc
            limit 1
          ) as ck
        from missing m
      ) bc
      on conflict (category_key, key) do nothing;
      get diagnostics v_ins_group = row_count;
    end if;
  end if;

  return jsonb_build_object(
    'dryRun', coalesce(p_dry_run, true),
    'missingCategories', to_jsonb(v_missing_cat),
    'missingUnitTypes', to_jsonb(v_missing_unit),
    'missingGroups', to_jsonb(v_missing_group),
    'inserted', jsonb_build_object(
      'categories', v_ins_cat,
      'unitTypes', v_ins_unit,
      'groups', v_ins_group
    )
  );
end;
$$;

revoke all on function public.repair_missing_item_meta_defs(boolean) from public;
revoke execute on function public.repair_missing_item_meta_defs(boolean) from anon;
grant execute on function public.repair_missing_item_meta_defs(boolean) to authenticated;

select pg_sleep(0.2);
notify pgrst, 'reload schema';

