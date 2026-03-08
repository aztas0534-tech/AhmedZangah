grant execute on function public.confirm_order_delivery_with_credit(uuid, jsonb, jsonb, uuid) to service_role, anon, authenticated;
grant execute on function public.confirm_order_delivery_with_credit(jsonb) to service_role, anon, authenticated;
grant execute on function public.confirm_order_delivery(uuid, jsonb, jsonb, uuid) to service_role, anon, authenticated;
grant execute on function public.confirm_order_delivery(jsonb) to service_role, anon, authenticated;
