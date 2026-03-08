create or replace function public.debug_stock_item()
returns jsonb
language plpgsql
security definer
as $$
declare
  v_res jsonb;
begin
  select coalesce(jsonb_agg(row_to_json(sm)), '[]'::jsonb)
  into v_res
  from public.stock_management sm
  where sm.item_id = 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a';
  return v_res;
end;
$$;
