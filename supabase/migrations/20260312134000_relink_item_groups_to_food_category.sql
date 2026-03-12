insert into public.item_categories (key, is_active, data)
values (
  'food',
  true,
  jsonb_build_object(
    'id', gen_random_uuid()::text,
    'key', 'food',
    'name', jsonb_build_object('ar', 'مواد غذائية', 'en', 'Food'),
    'isActive', true,
    'createdAt', now()::text,
    'updatedAt', now()::text
  )
)
on conflict (key) do update
set is_active = true,
    data = case
      when coalesce(public.item_categories.data->'name'->>'ar', '') = '' then
        public.item_categories.data || jsonb_build_object('name', jsonb_build_object('ar', 'مواد غذائية', 'en', 'Food'))
      else public.item_categories.data
    end;

delete from public.item_groups g
where coalesce(g.category_key, '') <> 'food'
  and exists (
    select 1
    from public.item_groups gf
    where gf.category_key = 'food'
      and gf.key = g.key
  );

update public.item_groups
set category_key = 'food'
where coalesce(category_key, '') <> 'food';

notify pgrst, 'reload schema';
