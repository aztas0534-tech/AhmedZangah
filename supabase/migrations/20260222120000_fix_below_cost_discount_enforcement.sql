create or replace function public.trg_block_sale_below_cost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch record;
  v_order jsonb;
  v_line jsonb;
  v_unit_price numeric;
  v_item_id text;
  v_fx numeric;
  v_currency text;
  v_unit_price_base numeric;
  v_subtotal numeric;
  v_discount numeric;
  v_discount_factor numeric;
begin
  if tg_op not in ('INSERT','UPDATE') then
    return new;
  end if;
  if new.movement_type <> 'sale_out' then
    return new;
  end if;
  if new.batch_id is null then
    return new;
  end if;
  if coalesce(new.reference_table,'') <> 'orders' or nullif(coalesce(new.reference_id,''),'') is null then
    return new;
  end if;

  select b.cost_per_unit, b.min_selling_price
  into v_batch
  from public.batches b
  where b.id = new.batch_id;

  select o.data, o.fx_rate, o.currency
  into v_order, v_fx, v_currency
  from public.orders o
  where o.id = (new.reference_id)::uuid;
  if v_order is null then
    return new;
  end if;

  v_item_id := new.item_id::text;
  v_unit_price := null;

  for v_line in
    select value from jsonb_array_elements(coalesce(v_order->'items','[]'::jsonb))
  loop
    if coalesce(nullif(v_line->>'id',''), nullif(v_line->>'itemId','')) = v_item_id then
      begin
        v_unit_price := nullif((v_line->>'price')::numeric, null);
      exception when others then
        v_unit_price := null;
      end;
      exit;
    end if;
  end loop;

  if v_unit_price is null then
    return new;
  end if;

  v_discount_factor := 1;
  v_subtotal := 0;
  begin
    v_subtotal := coalesce(nullif((v_order->>'subtotal')::numeric, null), 0);
  exception when others then
    v_subtotal := 0;
  end;
  v_discount := 0;
  begin
    v_discount := coalesce(nullif((v_order->>'discountAmount')::numeric, null), 0);
  exception when others then
    v_discount := 0;
  end;
  if v_discount <= 0 then
    begin
      v_discount := coalesce(nullif((v_order->>'discount_amount')::numeric, null), 0);
    exception when others then
      v_discount := 0;
    end;
  end if;
  if v_subtotal > 0 and v_discount > 0 then
    v_discount_factor := greatest(0, least(1, (v_subtotal - least(v_discount, v_subtotal)) / v_subtotal));
  end if;

  v_unit_price_base := coalesce(v_unit_price, 0) * coalesce(v_fx, 1) * coalesce(v_discount_factor, 1);
  if v_unit_price_base + 1e-9 < coalesce(v_batch.min_selling_price, 0) then
    if public.allow_below_cost_sales() then
      return new;
    end if;
    raise exception 'SELLING_BELOW_COST_NOT_ALLOWED';
  end if;

  return new;
end;
$$;

do $$
begin
  if to_regclass('public.inventory_movements') is not null then
    drop trigger if exists trg_block_sale_below_cost on public.inventory_movements;
    create trigger trg_block_sale_below_cost
    before insert or update on public.inventory_movements
    for each row execute function public.trg_block_sale_below_cost();
  end if;
end $$;

notify pgrst, 'reload schema';
