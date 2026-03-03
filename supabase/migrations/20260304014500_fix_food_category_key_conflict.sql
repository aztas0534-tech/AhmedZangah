-- ============================================================================
-- Fix: Category definition key still shows cat_1770925018742 instead of food
-- The previous migration updated menu_items.category but failed to update
-- item_categories.key due to a possible unique constraint conflict.
-- This migration handles the conflict properly.
-- ============================================================================

do $$
declare
  v_old_key text := 'cat_1770925018742';
  v_new_key text := 'food';
  v_old_exists boolean;
  v_new_exists boolean;
begin
  -- Check what exists
  select exists(select 1 from public.item_categories where key = v_old_key) into v_old_exists;
  select exists(select 1 from public.item_categories where key = v_new_key) into v_new_exists;

  if v_old_exists and v_new_exists then
    -- Both exist: merge by deleting the old one (items already point to 'food')
    delete from public.item_categories where key = v_old_key;
    raise notice 'Deleted duplicate category key: %', v_old_key;
  elsif v_old_exists and not v_new_exists then
    -- Only old exists: safe to rename
    update public.item_categories
    set key = v_new_key, updated_at = now()
    where key = v_old_key;
    raise notice 'Renamed category key from % to %', v_old_key, v_new_key;
  elsif not v_old_exists and v_new_exists then
    raise notice 'Category key already correct: %', v_new_key;
  else
    raise notice 'Neither key found - no action needed';
  end if;

  -- Ensure all menu items with the old key are updated
  update public.menu_items
  set category = v_new_key, updated_at = now()
  where category = v_old_key;
end;
$$;

-- Also catch any other auto-generated cat_ keys for food-like categories
do $$
declare
  v_cat record;
begin
  for v_cat in
    select ic.key, ic.data
    from public.item_categories ic
    where ic.key like 'cat_%'
      and (
        coalesce(ic.data->>'name_ar', ic.data->'name'->>'ar', '') like '%غذ%'
        or lower(coalesce(ic.data->>'name_en', ic.data->'name'->>'en', '')) like '%food%'
      )
  loop
    -- Update items that reference this category
    update public.menu_items
    set category = 'food', updated_at = now()
    where category = v_cat.key;
    
    -- Remove the duplicate category definition
    delete from public.item_categories where key = v_cat.key;
    raise notice 'Merged food-like category: %', v_cat.key;
  end loop;
end;
$$;
