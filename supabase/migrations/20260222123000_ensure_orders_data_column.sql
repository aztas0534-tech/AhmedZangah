do $$
begin
  if to_regclass('public.orders') is null then
    return;
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'orders'
      and column_name = 'data'
  ) then
    alter table public.orders
      add column data jsonb not null default '{}'::jsonb;
  end if;

  begin
    update public.orders
    set data = '{}'::jsonb
    where data is null;
  exception when others then
    null;
  end;

  begin
    update public.orders
    set data = jsonb_strip_nulls(
      jsonb_build_object(
        'id', id::text,
        'status', status,
        'currency', currency,
        'subtotal', subtotal,
        'discountAmount', discount,
        'deliveryFee', delivery_fee,
        'taxAmount', tax_amount,
        'total', total,
        'items', items,
        'customerName', customer_name,
        'phoneNumber', phone_number,
        'notes', notes,
        'address', address,
        'deliveryZoneId', delivery_zone_id::text,
        'warehouseId', warehouse_id::text,
        'orderSource', coalesce(nullif(data->>'orderSource',''), nullif(data->>'source',''), null)
      )
    )
    where (data = '{}'::jsonb or data is null);
  exception when others then
    null;
  end;
end $$;

notify pgrst, 'reload schema';
