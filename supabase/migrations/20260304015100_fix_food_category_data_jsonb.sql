-- ============================================================================
-- Fix: Update 'key' inside the data jsonb for the food category
-- The previous migration updated item_categories.key but NOT data->key,
-- and the frontend reads key from data first (d.key).
-- ============================================================================

-- Update the 'key' field inside the data jsonb for the food category
update public.item_categories
set data = jsonb_set(data, '{key}', '"food"'::jsonb),
    updated_at = now()
where key = 'food'
  and data->>'key' is not null
  and data->>'key' <> 'food';

-- Also fix any remaining cat_1770925018742 references
update public.item_categories
set key = 'food',
    data = jsonb_set(data, '{key}', '"food"'::jsonb),
    updated_at = now()
where data->>'key' = 'cat_1770925018742';
