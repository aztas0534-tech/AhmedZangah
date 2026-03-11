-- ============================================================================
-- Migration: Fix Food Category Detection
-- Problem: Category "مواد غذائية" has key "cat_1770925018742" but ALL code
--          (50+ SQL functions + frontend) checks for category = 'food'.
--          Result: zero food safety features working for 80+ items.
-- Fix: Rename category key to 'food' + update all items + add helper function.
-- ============================================================================

-- ── 1) Create helper function for food detection (future-proof) ──
create or replace function public.is_food_category(p_category text)
returns boolean
language sql
stable
as $$
  select coalesce(p_category, '') in ('food')
      or lower(coalesce(p_category, '')) in ('food', 'grocery', 'groceries')
      or exists (
        select 1 from public.item_categories ic
        where ic.key = p_category
          and (
            coalesce(ic.data->>'name_ar', ic.data->'name'->>'ar', '') like '%غذ%'
            or lower(coalesce(ic.data->>'name_en', ic.data->'name'->>'en', '')) like '%food%'
          )
      );
$$;

-- ── 2) Update all menu_items that reference cat_1770925018742 to 'food' ──
update public.menu_items
set category = 'food',
    updated_at = now()
where category = 'cat_1770925018742';

-- Also update in the data jsonb column if it exists there
update public.menu_items
set data = jsonb_set(data, '{category}', '"food"'::jsonb),
    updated_at = now()
where data->>'category' = 'cat_1770925018742';

-- ── 3) Update the category definition itself ──
update public.item_categories
set key = 'food',
    updated_at = now()
where key = 'cat_1770925018742';

-- ── 4) Catch any other food-like categories with auto-generated keys ──
update public.menu_items
set category = 'food',
    updated_at = now()
where category in (
  select ic.key 
  from public.item_categories ic
  where ic.key <> 'food'
    and ic.key like 'cat_%'
    and (
      coalesce(ic.data->>'name_ar', ic.data->'name'->>'ar', '') like '%غذ%'
      or lower(coalesce(ic.data->>'name_en', ic.data->'name'->>'en', '')) like '%food%'
    )
)
and category <> 'food';

-- ── 5) Log what we did ──
do $$
declare
  v_count int;
begin
  select count(*) into v_count from public.menu_items where category = 'food';
  raise notice 'Food category fix: % items now have category = food', v_count;
end;
$$;

notify pgrst, 'reload schema';
