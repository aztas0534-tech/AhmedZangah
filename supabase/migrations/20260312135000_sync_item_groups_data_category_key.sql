update public.item_groups
set data = jsonb_set(
  coalesce(data, '{}'::jsonb),
  '{categoryKey}',
  to_jsonb(category_key),
  true
)
where coalesce(data->>'categoryKey', '') is distinct from coalesce(category_key, '');

notify pgrst, 'reload schema';
