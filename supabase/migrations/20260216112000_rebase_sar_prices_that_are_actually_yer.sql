do $$
declare
  v_base text;
  v_fx numeric;
  v_threshold numeric := 1000;
  v_done boolean := false;
  v_rows int := 0;
  v_rows2 int := 0;
  v_rows3 int := 0;
  v_rows4 int := 0;
  v_rows5 int := 0;
  v_rows6 int := 0;
begin
  v_base := public.get_base_currency();
  if upper(v_base) <> 'SAR' then
    raise exception 'This rebase expects base currency SAR (got %)', v_base;
  end if;

  begin
    select (coalesce(nullif(btrim(coalesce(s.data->'settings'->>'prices_rebased_yer_to_sar','')), ''), 'false'))::boolean
    into v_done
    from public.app_settings s
    where s.id = 'app'
    limit 1;
  exception when others then
    v_done := false;
  end;

  if v_done then
    return;
  end if;

  v_fx := public.get_fx_rate('YER', current_date, 'operational');
  if v_fx is null or v_fx <= 0 then
    raise exception 'Missing/invalid FX for YER on %', current_date;
  end if;

  update public.menu_items mi
  set data =
    (case
      when (mi.data ? 'price') and coalesce(nullif(btrim(mi.data->>'price'),''),'0')::numeric > v_threshold
        then jsonb_set(mi.data, '{price}', to_jsonb(round(coalesce(nullif(btrim(mi.data->>'price'),''),'0')::numeric * v_fx, 4)), true)
      else mi.data
    end);
  get diagnostics v_rows = row_count;

  update public.menu_items mi
  set data =
    (case
      when (mi.data ? 'pricePerUnit') and coalesce(nullif(btrim(mi.data->>'pricePerUnit'),''),'0')::numeric > v_threshold
        then jsonb_set(mi.data, '{pricePerUnit}', to_jsonb(round(coalesce(nullif(btrim(mi.data->>'pricePerUnit'),''),'0')::numeric * v_fx, 4)), true)
      else mi.data
    end)
  where (mi.data ? 'pricePerUnit');
  get diagnostics v_rows2 = row_count;

  update public.menu_items mi
  set data =
    (case
      when (mi.data ? 'addons') and jsonb_typeof(mi.data->'addons') = 'array' then
        jsonb_set(
          mi.data,
          '{addons}',
          coalesce((
            select jsonb_agg(
              case
                when (a.value ? 'price') and coalesce(nullif(btrim(a.value->>'price'),''),'0')::numeric > v_threshold
                  then jsonb_set(a.value, '{price}', to_jsonb(round(coalesce(nullif(btrim(a.value->>'price'),''),'0')::numeric * v_fx, 4)), true)
                else a.value
              end
            )
            from jsonb_array_elements(mi.data->'addons') as a(value)
          ), '[]'::jsonb),
          true
        )
      else mi.data
    end)
  where (mi.data ? 'addons') and jsonb_typeof(mi.data->'addons') = 'array';
  get diagnostics v_rows3 = row_count;

  update public.price_tiers
  set price = round(price * v_fx, 4)
  where price is not null
    and price > v_threshold;
  get diagnostics v_rows4 = row_count;

  update public.customer_special_prices
  set special_price = round(special_price * v_fx, 4)
  where special_price is not null
    and special_price > v_threshold;
  get diagnostics v_rows5 = row_count;

  update public.batches b
  set min_selling_price = round(b.min_selling_price * v_fx, 4)
  where b.min_selling_price is not null
    and b.min_selling_price > v_threshold;
  get diagnostics v_rows6 = row_count;

  update public.product_prices_multi_currency
  set price_value = round(price_value * v_fx, 4)
  where upper(currency_code) = 'SAR'
    and price_value is not null
    and price_value > v_threshold;

  update public.batch_prices_multi_currency
  set price_value = round(price_value * v_fx, 4)
  where upper(currency_code) = 'SAR'
    and price_value is not null
    and price_value > v_threshold;

  update public.app_settings
  set data = jsonb_set(
    coalesce(data, '{}'::jsonb),
    '{settings,prices_rebased_yer_to_sar}',
    to_jsonb(true),
    true
  ),
  updated_at = now()
  where id in ('app','singleton');
end $$;

notify pgrst, 'reload schema';
