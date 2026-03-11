set app.allow_ledger_ddl = '1';

create or replace function public.recompute_order_return_status(p_order_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_order record;
  v_total_qty numeric := 0;
  v_returned_qty numeric := 0;
  v_any_return boolean := false;
  v_status text := null;
  v_existing_returned_at timestamptz := null;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    return;
  end if;

  v_existing_returned_at := nullif(btrim(coalesce(v_order.data->>'returnedAt', '')), '');

  select
    coalesce(sum( (item->>'quantity')::numeric ), 0)
  into v_total_qty
  from jsonb_array_elements(coalesce(v_order.data->'items', '[]'::jsonb)) item;

  select
    coalesce(sum( (ri->>'quantity')::numeric ), 0)
  into v_returned_qty
  from public.sales_returns sr
  cross join lateral jsonb_array_elements(coalesce(sr.items, '[]'::jsonb)) ri
  where sr.order_id = p_order_id
    and sr.status = 'completed';

  select exists(
    select 1 from public.sales_returns
    where order_id = p_order_id
      and status = 'completed'
  )
  into v_any_return;

  if not v_any_return then
    begin
      update public.orders
      set data = coalesce(data, '{}'::jsonb) - 'returnStatus' - 'returnedAt' - 'returnUpdatedAt'
      where id = p_order_id;
    exception when others then
      null;
    end;
    return;
  end if;

  if v_total_qty <= 0 then
    v_status := 'partial';
  elsif v_returned_qty >= v_total_qty then
    v_status := 'full';
  else
    v_status := 'partial';
  end if;

  begin
    update public.orders
    set data = jsonb_set(
      jsonb_set(
        jsonb_set(
          coalesce(data, '{}'::jsonb),
          '{returnStatus}',
          to_jsonb(v_status),
          true
        ),
        '{returnedAt}',
        to_jsonb(coalesce(v_existing_returned_at, now())),
        true
      ),
      '{returnUpdatedAt}',
      to_jsonb(now()),
      true
    )
    where id = p_order_id;
  exception when others then
    null;
  end;
end;
$$;

notify pgrst, 'reload schema';

