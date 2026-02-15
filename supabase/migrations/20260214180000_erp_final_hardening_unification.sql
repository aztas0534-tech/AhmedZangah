do $$ begin if to_regclass('public.fx_rates') is not null then revoke select on public.fx_rates from public; revoke select on public.fx_rates from anon; revoke select on public.fx_rates from authenticated; grant select on public.fx_rates to service_role; end if; end $$;

create or replace function public.get_fx_rate_rpc(p_currency_code text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_base text;
  v numeric;
begin
  v_code := upper(nullif(btrim(coalesce(p_currency_code,'')),''));
  if v_code is null then
    return 1;
  end if;
  v := public.get_fx_rate(v_code, current_date, 'operational');
  return v;
end;
$$;
revoke all on function public.get_fx_rate_rpc(text) from public;
grant execute on function public.get_fx_rate_rpc(text) to authenticated;

do $$
begin
  if to_regprocedure('public.get_item_price_with_discount(text,uuid,numeric)') is not null then
    revoke execute on function public.get_item_price_with_discount(text, uuid, numeric) from public;
    revoke execute on function public.get_item_price_with_discount(text, uuid, numeric) from anon;
    revoke execute on function public.get_item_price_with_discount(text, uuid, numeric) from authenticated;
    grant execute on function public.get_item_price_with_discount(text, uuid, numeric) to service_role;
  end if;
end $$;

do $$
begin
  if to_regprocedure('public.resolve_item_price(text,text,numeric,date)') is not null then
    revoke execute on function public.resolve_item_price(text, text, numeric, date) from public;
    revoke execute on function public.resolve_item_price(text, text, numeric, date) from anon;
    revoke execute on function public.resolve_item_price(text, text, numeric, date) from authenticated;
    grant execute on function public.resolve_item_price(text, text, numeric, date) to service_role;
  end if;
  if to_regprocedure('public.resolve_item_price(text,text,numeric,date,uuid)') is not null then
    revoke execute on function public.resolve_item_price(text, text, numeric, date, uuid) from public;
    revoke execute on function public.resolve_item_price(text, text, numeric, date, uuid) from anon;
    revoke execute on function public.resolve_item_price(text, text, numeric, date, uuid) from authenticated;
    grant execute on function public.resolve_item_price(text, text, numeric, date, uuid) to service_role;
  end if;
  if to_regprocedure('public.resolve_item_price(text,uuid,text,numeric,date,uuid)') is not null then
    revoke execute on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) from public;
    revoke execute on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) from anon;
    revoke execute on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) from authenticated;
    grant execute on function public.resolve_item_price(text, uuid, text, numeric, date, uuid) to service_role;
  end if;
end $$;

create or replace function public.get_fefo_pricing(
  p_item_id text,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_customer_id uuid default null,
  p_currency_code text default null
)
returns table (
  batch_id uuid,
  unit_cost numeric,
  min_price numeric,
  suggested_price numeric,
  batch_code text,
  expiry_date date,
  next_batch_min_price numeric,
  warning_next_batch_price_diff boolean,
  reason_code text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_qty numeric := greatest(coalesce(p_quantity, 0), 0);
  v_batch record;
  v_next record;
  v_base_price numeric := 0;
  v_total_released numeric := 0;
  v_has_nonexpired_unreleased boolean := false;
  v_currency text;
begin
  if nullif(btrim(coalesce(p_item_id, '')), '') is null then
    raise exception 'p_item_id is required';
  end if;
  if p_warehouse_id is null then
    raise exception 'p_warehouse_id is required';
  end if;
  if v_qty <= 0 then
    v_qty := 1;
  end if;

  select
    b.id,
    b.cost_per_unit,
    b.min_selling_price,
    b.batch_code,
    b.expiry_date,
    greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) as remaining
  into v_batch
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
    and coalesce(b.qc_status,'released') = 'released'
  order by b.expiry_date asc nulls last, b.created_at asc, b.id asc
  limit 1;

  select exists(
    select 1
    from public.batches b
    where b.item_id::text = p_item_id::text
      and b.warehouse_id = p_warehouse_id
      and coalesce(b.status, 'active') = 'active'
      and (b.expiry_date is null or b.expiry_date >= current_date)
      and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
      and coalesce(b.qc_status,'released') <> 'released'
  ) into v_has_nonexpired_unreleased;

  if v_batch.id is null then
    reason_code := case when v_has_nonexpired_unreleased then 'BATCH_NOT_RELEASED' else 'NO_VALID_BATCH' end;
    batch_id := null;
    unit_cost := null;
    min_price := 0;
    suggested_price := 0;
    batch_code := null;
    expiry_date := null;
    next_batch_min_price := null;
    warning_next_batch_price_diff := false;
    return next;
  end if;

  select coalesce(sum(greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0)), 0)
  into v_total_released
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and coalesce(b.qc_status,'released') = 'released';

  if v_total_released + 1e-9 < v_qty then
    reason_code := 'INSUFFICIENT_BATCH_QUANTITY';
  else
    reason_code := null;
  end if;

  v_currency := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  v_base_price := public.resolve_item_price(
    p_item_id::text,
    p_warehouse_id,
    coalesce(v_currency, public.get_base_currency()),
    v_qty,
    current_date,
    p_customer_id
  );

  batch_id := v_batch.id;
  unit_cost := case when auth.role() = 'service_role' then coalesce(v_batch.cost_per_unit, 0) else null end;
  min_price := coalesce(v_batch.min_selling_price, 0);
  suggested_price := greatest(coalesce(v_base_price, 0), coalesce(v_batch.min_selling_price, 0));
  batch_code := v_batch.batch_code;
  expiry_date := v_batch.expiry_date;

  select b.min_selling_price
  into v_next
  from public.batches b
  where b.item_id::text = p_item_id::text
    and b.warehouse_id = p_warehouse_id
    and coalesce(b.status, 'active') = 'active'
    and (b.expiry_date is null or b.expiry_date >= current_date)
    and greatest(coalesce(b.quantity_received,0) - coalesce(b.quantity_consumed,0) - coalesce(b.quantity_transferred,0), 0) > 0
    and coalesce(b.qc_status,'released') = 'released'
    and b.id <> v_batch.id
  order by b.expiry_date asc nulls last, b.created_at asc
  limit 1;

  next_batch_min_price := nullif(coalesce(v_next.min_selling_price, null), null);
  warning_next_batch_price_diff := case when next_batch_min_price is null then false else abs(next_batch_min_price - min_price) > 1e-9 end;

  return next;
end;
$$;
revoke all on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) from public;
grant execute on function public.get_fefo_pricing(text, uuid, numeric, uuid, text) to authenticated;

create or replace function public.create_order_secure(
    p_items jsonb,
    p_delivery_zone_id uuid,
    p_payment_method text,
    p_notes text,
    p_address text,
    p_location jsonb,
    p_customer_name text,
    p_phone_number text,
    p_is_scheduled boolean,
    p_scheduled_at timestamptz,
    p_coupon_code text default null,
    p_points_redeemed_value numeric default 0,
    p_explicit_customer_id uuid default null,
    p_order_source text default 'online',
    p_currency text default null,
    p_warehouse_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user_id uuid;
    v_order_id uuid;
    v_item_input jsonb;
    v_menu_item record;
    v_menu_item_data jsonb;
    v_cart_item jsonb;
    v_final_items jsonb := '[]'::jsonb;
    v_subtotal numeric := 0;
    v_total numeric := 0;
    v_delivery_fee numeric := 0;
    v_discount_amount numeric := 0;
    v_tax_amount numeric := 0;
    v_tax_rate numeric := 0;
    v_points_earned numeric := 0;
    v_settings jsonb;
    v_zone_data jsonb;
    v_line_total numeric;
    v_addons_price numeric;
    v_unit_price numeric;
    v_base_price numeric;
    v_addon_key text;
    v_addon_qty numeric;
    v_addon_def jsonb;
    v_grade_id text;
    v_grade_def jsonb;
    v_weight numeric;
    v_quantity numeric;
    v_unit_type text;
    v_delivery_pin text;
    v_available_addons jsonb;
    v_selected_addons_map jsonb;
    v_final_selected_addons jsonb;
    v_points_settings jsonb;
    v_currency_val_per_point numeric;
    v_points_per_currency numeric;
    v_coupon_record record;
    v_stock_items jsonb := '[]'::jsonb;
    v_item_name_ar text;
    v_item_name_en text;
    v_priced_unit numeric;
    v_pricing_qty numeric;
    v_warehouse_id uuid;
    v_stock_qty numeric;
    v_has_promotions boolean := false;
    v_promotion_id uuid;
    v_bundle_qty numeric;
    v_promo_snapshot jsonb;
    v_promotion_lines jsonb := '[]'::jsonb;
    v_promo_line_id uuid;
    v_promo_item jsonb;
    v_is_staff boolean := false;
    v_base_currency text;
    v_currency text;
    v_fx_rate numeric := 1;
    v_subtotal_tx numeric := 0;
    v_total_tx numeric := 0;
    v_delivery_fee_tx numeric := 0;
    v_discount_amount_tx numeric := 0;
    v_tax_amount_tx numeric := 0;
    v_points_redeemed_value_tx numeric := 0;
    v_addon_def_tx jsonb;
begin
    v_user_id := auth.uid();
    if v_user_id is null then
        raise exception 'User not authenticated';
    end if;

    if exists (
      select 1 from public.admin_users au
      where au.auth_user_id = v_user_id and au.is_active = true
      limit 1
    ) then
      v_is_staff := true;
    end if;

    if v_is_staff then
       if p_order_source = 'online' and p_explicit_customer_id is null then
          raise exception 'not_allowed';
       end if;
       if p_explicit_customer_id is not null then
          v_user_id := p_explicit_customer_id;
       elsif p_order_source = 'in_store' then
          v_user_id := null;
       end if;
    end if;

    v_warehouse_id := coalesce(p_warehouse_id, public._resolve_default_warehouse_id());

    select data into v_settings from public.app_settings where id = 'singleton';
    if v_settings is null then
        v_settings := '{}'::jsonb;
    end if;

    v_base_currency := public.get_base_currency();
    v_currency := upper(nullif(btrim(coalesce(p_currency, '')), ''));
    if v_currency is null then
      v_currency := v_base_currency;
    end if;
    if v_currency = v_base_currency then
      v_fx_rate := 1;
    else
      v_fx_rate := public.get_fx_rate(v_currency, current_date, 'operational');
      if v_fx_rate is null or not (v_fx_rate > 0) then
        raise exception 'invalid_fx';
      end if;
    end if;

    if p_items is null or jsonb_typeof(p_items) <> 'array' then
      raise exception 'p_items must be a json array';
    end if;

    for v_item_input in select * from jsonb_array_elements(p_items)
    loop
        v_promotion_id := public._uuid_or_null(v_item_input->>'promotionId');
        if v_promotion_id is not null or coalesce(nullif(v_item_input->>'lineType',''), '') = 'promotion' then
          v_has_promotions := true;
          v_bundle_qty := coalesce(nullif((v_item_input->>'bundleQty')::numeric, null), nullif((v_item_input->>'quantity')::numeric, null), 1);
          if v_bundle_qty <= 0 then v_bundle_qty := 1; end if;
          if p_coupon_code is not null and length(p_coupon_code) > 0 then
            raise exception 'promotion_coupon_conflict';
          end if;
          if coalesce(p_points_redeemed_value, 0) > 0 then
            raise exception 'promotion_points_conflict';
          end if;
          v_promo_snapshot := public._compute_promotion_snapshot(v_promotion_id, v_user_id, v_warehouse_id, v_bundle_qty, null, true);
          v_promo_line_id := gen_random_uuid();
          v_cart_item := jsonb_build_object(
            'lineType', 'promotion',
            'promotionId', v_promotion_id::text,
            'promotionLineId', v_promo_line_id::text,
            'name', v_promo_snapshot->>'name',
            'bundleQty', coalesce(nullif((v_promo_snapshot->>'bundleQty')::numeric, null), v_bundle_qty),
            'originalTotal', public._money_round(coalesce(nullif((v_promo_snapshot->>'computedOriginalTotal')::numeric, null), 0) / v_fx_rate),
            'finalTotal', public._money_round(coalesce(nullif((v_promo_snapshot->>'finalTotal')::numeric, null), 0) / v_fx_rate),
            'promotionExpense', public._money_round(coalesce(nullif((v_promo_snapshot->>'promotionExpense')::numeric, null), 0) / v_fx_rate),
            'cartItemId', coalesce(nullif(v_item_input->>'cartItemId',''), gen_random_uuid()::text)
          );
          v_final_items := v_final_items || v_cart_item;
          v_subtotal := v_subtotal + coalesce(nullif((v_promo_snapshot->>'finalTotal')::numeric, null), 0);
          v_promotion_lines := v_promotion_lines || jsonb_build_object(
            'promotionId', v_promotion_id::text,
            'promotionLineId', v_promo_line_id::text,
            'bundleQty', v_bundle_qty,
            'snapshot', v_promo_snapshot
          );
          continue;
        end if;

        select * into v_menu_item from public.menu_items where id = (v_item_input->>'itemId');
        if not found then
            raise exception 'Item not found: %', v_item_input->>'itemId';
        end if;

        v_menu_item_data := v_menu_item.data;
        v_item_name_ar := v_menu_item_data->'name'->>'ar';
        v_item_name_en := v_menu_item_data->'name'->>'en';

        v_quantity := coalesce((v_item_input->>'quantity')::numeric, 0);
        v_weight := coalesce((v_item_input->>'weight')::numeric, 0);
        v_unit_type := coalesce(v_menu_item.unit_type, 'piece');

        if v_unit_type in ('kg', 'gram') then
            if v_quantity <= 0 then v_quantity := 1; end if;
            v_pricing_qty := case when v_weight > 0 then v_weight else v_quantity end;
            select suggested_price into v_priced_unit from public.get_fefo_pricing(v_menu_item.id::text, v_warehouse_id, v_pricing_qty, v_user_id, v_base_currency) limit 1;
            v_base_price := v_priced_unit * v_weight;
            v_stock_qty := v_weight;
        else
            if v_quantity <= 0 then raise exception 'Quantity must be positive for item %', v_menu_item.id; end if;
            v_pricing_qty := v_quantity;
            select suggested_price into v_priced_unit from public.get_fefo_pricing(v_menu_item.id::text, v_warehouse_id, v_pricing_qty, v_user_id, v_base_currency) limit 1;
            v_base_price := v_priced_unit;
            v_stock_qty := v_quantity;
        end if;

        v_grade_id := v_item_input->>'gradeId';
        v_grade_def := null;
        if v_grade_id is not null and (v_menu_item_data->'availableGrades') is not null then
            select value into v_grade_def from jsonb_array_elements(v_menu_item_data->'availableGrades') where value->>'id' = v_grade_id;
            if v_grade_def is not null then
                v_priced_unit := v_priced_unit * coalesce((v_grade_def->>'priceMultiplier')::numeric, 1.0);
                v_base_price := v_base_price * coalesce((v_grade_def->>'priceMultiplier')::numeric, 1.0);
            end if;
        end if;

        v_addons_price := 0;
        v_available_addons := coalesce(v_menu_item_data->'addons', '[]'::jsonb);
        v_selected_addons_map := coalesce(v_item_input->'selectedAddons', '{}'::jsonb);
        v_final_selected_addons := '{}'::jsonb;

        for v_addon_key in select jsonb_object_keys(v_selected_addons_map)
        loop
            v_addon_qty := (v_selected_addons_map->>v_addon_key)::numeric;
            if v_addon_qty > 0 then
                select value into v_addon_def from jsonb_array_elements(v_available_addons) where value->>'id' = v_addon_key;
                if v_addon_def is not null then
                    v_addons_price := v_addons_price + ((v_addon_def->>'price')::numeric * v_addon_qty);
                    v_addon_def_tx := jsonb_set(v_addon_def, '{price}', to_jsonb(public._money_round(((v_addon_def->>'price')::numeric) / v_fx_rate)), true);
                    v_final_selected_addons := jsonb_set(v_final_selected_addons, array[v_addon_key], jsonb_build_object('addon', v_addon_def_tx, 'quantity', v_addon_qty));
                end if;
            end if;
        end loop;

        if v_unit_type in ('kg', 'gram') then
            v_unit_price := v_base_price + v_addons_price;
            v_line_total := (v_base_price + v_addons_price) * v_quantity;
        else
            v_unit_price := v_priced_unit + v_addons_price;
            v_line_total := (v_priced_unit + v_addons_price) * v_quantity;
        end if;

        v_subtotal := v_subtotal + v_line_total;

        v_cart_item := v_menu_item_data || jsonb_build_object(
            'quantity', v_quantity,
            'weight', v_weight,
            'selectedAddons', v_final_selected_addons,
            'selectedGrade', v_grade_def,
            'cartItemId', gen_random_uuid()::text,
            'price', public._money_round(v_priced_unit / v_fx_rate)
        );
        if v_unit_type = 'gram' then
          v_cart_item := v_cart_item || jsonb_build_object('pricePerUnit', public._money_round((v_priced_unit / v_fx_rate) * 1000));
        end if;

        v_final_items := v_final_items || v_cart_item;

        v_stock_items := v_stock_items || jsonb_build_object(
            'itemId', v_menu_item.id,
            'quantity', v_stock_qty
        );
    end loop;

    if p_delivery_zone_id is not null then
        select data into v_zone_data from public.delivery_zones where id = p_delivery_zone_id;
        if v_zone_data is not null and (v_zone_data->>'isActive')::boolean then
            v_delivery_fee := coalesce((v_zone_data->>'deliveryFee')::numeric, 0);
        else
            v_delivery_fee := coalesce((v_settings->'deliverySettings'->>'baseFee')::numeric, 0);
        end if;
    else
        v_delivery_fee := coalesce((v_settings->'deliverySettings'->>'baseFee')::numeric, 0);
    end if;

    if (v_settings->'deliverySettings'->>'freeDeliveryThreshold') is not null and v_subtotal >= (v_settings->'deliverySettings'->>'freeDeliveryThreshold')::numeric then
        v_delivery_fee := 0;
    end if;

    if not v_has_promotions and p_coupon_code is not null and length(p_coupon_code) > 0 then
        select * into v_coupon_record from public.coupons where lower(code) = lower(p_coupon_code) and is_active = true;
        if found then
            if (v_coupon_record.data->>'expiresAt') is not null and (v_coupon_record.data->>'expiresAt')::timestamptz < now() then
                raise exception 'coupon_expired';
            end if;
            if (v_coupon_record.data->>'minOrderAmount') is not null and v_subtotal < (v_coupon_record.data->>'minOrderAmount')::numeric then
                raise exception 'low_amount';
            end if;
            if (v_coupon_record.data->>'usageLimit') is not null and coalesce((v_coupon_record.data->>'usageCount')::int, 0) >= (v_coupon_record.data->>'usageLimit')::int then
                raise exception 'coupon_limit';
            end if;
            if (v_coupon_record.data->>'type') = 'percentage' then
                v_discount_amount := v_subtotal * ((v_coupon_record.data->>'value')::numeric / 100);
                if (v_coupon_record.data->>'maxDiscount') is not null then
                    v_discount_amount := least(v_discount_amount, (v_coupon_record.data->>'maxDiscount')::numeric);
                end if;
            else
                v_discount_amount := (v_coupon_record.data->>'value')::numeric;
            end if;
            v_discount_amount := least(v_discount_amount, v_subtotal);
            update public.coupons set data = jsonb_set(data, '{usageCount}', (coalesce((data->>'usageCount')::int, 0) + 1)::text::jsonb) where id = v_coupon_record.id;
        else
            v_discount_amount := 0;
        end if;
    end if;

    if not v_has_promotions and p_points_redeemed_value > 0 then
        v_points_settings := v_settings->'loyaltySettings';
        if (v_points_settings->>'enabled')::boolean then
            v_currency_val_per_point := coalesce((v_points_settings->>'currencyValuePerPoint')::numeric, 0);
            if v_currency_val_per_point > 0 then
                declare v_user_points int; v_points_needed numeric; begin
                    if v_user_id is null then raise exception 'walkin_no_points'; end if;
                    select loyalty_points into v_user_points from public.customers where auth_user_id = v_user_id;
                    v_points_needed := p_points_redeemed_value / v_currency_val_per_point;
                    if coalesce(v_user_points, 0) < v_points_needed then raise exception 'insufficient_points'; end if;
                    update public.customers set loyalty_points = loyalty_points - v_points_needed::int where auth_user_id = v_user_id;
                    v_discount_amount := v_discount_amount + p_points_redeemed_value;
                end;
            end if;
        end if;
    end if;

    if (v_settings->'taxSettings'->>'enabled')::boolean then
        v_tax_rate := coalesce((v_settings->'taxSettings'->>'rate')::numeric, 0);
        v_tax_amount := greatest(0, v_subtotal - v_discount_amount) * (v_tax_rate / 100);
    end if;

    v_total := greatest(0, v_subtotal - v_discount_amount) + v_delivery_fee + v_tax_amount;

    v_points_settings := v_settings->'loyaltySettings';
    if (v_points_settings->>'enabled')::boolean then
        v_points_per_currency := coalesce((v_points_settings->>'pointsPerCurrencyUnit')::numeric, 0);
        v_points_earned := floor(v_subtotal * v_points_per_currency);
    end if;

    v_delivery_pin := floor(random() * 9000 + 1000)::text;

    v_stock_items := public._merge_stock_items(v_stock_items);

    v_subtotal_tx := public._money_round(v_subtotal / v_fx_rate);
    v_delivery_fee_tx := public._money_round(v_delivery_fee / v_fx_rate);
    v_discount_amount_tx := public._money_round(v_discount_amount / v_fx_rate);
    v_tax_amount_tx := public._money_round(v_tax_amount / v_fx_rate);
    v_total_tx := public._money_round(v_total / v_fx_rate);
    v_points_redeemed_value_tx := public._money_round(coalesce(p_points_redeemed_value, 0) / v_fx_rate);

    insert into public.orders (customer_auth_user_id, status, invoice_number, data)
    values (
        v_user_id,
        case when p_is_scheduled then 'scheduled' else 'pending' end,
        null,
        jsonb_build_object(
            'id', gen_random_uuid(),
            'userId', v_user_id,
            'orderSource', p_order_source,
            'currency', v_currency,
            'fxRate', v_fx_rate,
            'baseCurrency', v_base_currency,
            'items', v_final_items,
            'promotionLines', case when v_has_promotions then v_promotion_lines else '[]'::jsonb end,
            'subtotal', v_subtotal_tx,
            'deliveryFee', v_delivery_fee_tx,
            'discountAmount', v_discount_amount_tx,
            'total', v_total_tx,
            'taxAmount', v_tax_amount_tx,
            'taxRate', v_tax_rate,
            'pointsEarned', v_points_earned,
            'pointsRedeemedValue', v_points_redeemed_value_tx,
            'deliveryZoneId', p_delivery_zone_id,
            'paymentMethod', p_payment_method,
            'notes', p_notes,
            'address', p_address,
            'location', p_location,
            'customerName', p_customer_name,
            'phoneNumber', p_phone_number,
            'isScheduled', p_is_scheduled,
            'scheduledAt', p_scheduled_at,
            'deliveryPin', v_delivery_pin,
            'appliedCouponCode', p_coupon_code,
            'warehouseId', v_warehouse_id
        )
    )
    returning id into v_order_id;

    update public.orders set data = jsonb_set(data, '{id}', to_jsonb(v_order_id::text)) where id = v_order_id returning data into v_item_input;

    perform public.reserve_stock_for_order(v_stock_items, v_order_id, v_warehouse_id);

    if v_has_promotions then
      for v_promo_snapshot in select value from jsonb_array_elements(v_promotion_lines)
      loop
        insert into public.promotion_usage(promotion_id, promotion_line_id, order_id, bundle_qty, channel, warehouse_id, snapshot, created_by)
        values ((v_promo_snapshot->>'promotionId')::uuid, (v_promo_snapshot->>'promotionLineId')::uuid, v_order_id, coalesce(nullif((v_promo_snapshot->>'bundleQty')::numeric, null), 1), p_order_source, v_warehouse_id, v_promo_snapshot, auth.uid());
      end loop;
    end if;

    insert into public.order_events (order_id, action, actor_type, actor_id, to_status, payload)
    values (v_order_id, 'order.created', 'customer', coalesce(v_user_id, auth.uid()), case when p_is_scheduled then 'scheduled' else 'pending' end, jsonb_build_object('total', v_total_tx, 'method', p_payment_method, 'currency', v_currency, 'fxRate', v_fx_rate));

    return v_item_input;
end;
$$;
revoke all on function public.create_order_secure(jsonb, uuid, text, text, text, jsonb, text, text, boolean, timestamptz, text, numeric, uuid, text, text, uuid) from public;
grant execute on function public.create_order_secure(jsonb, uuid, text, text, text, jsonb, text, text, boolean, timestamptz, text, numeric, uuid, text, text, uuid) to authenticated;

drop function if exists public.confirm_order_delivery(uuid, jsonb, jsonb, uuid);

create or replace function public.confirm_order_delivery(
    p_order_id uuid,
    p_items jsonb,
    p_updated_data jsonb,
    p_warehouse_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_actor uuid;
    v_order record;
    v_order_data jsonb;
    v_promos jsonb;
    v_promos_fixed jsonb := '[]'::jsonb;
    v_line jsonb;
    v_snapshot jsonb;
    v_items_all jsonb := '[]'::jsonb;
    v_item jsonb;
    v_final_data jsonb;
    v_is_cod boolean := false;
    v_driver_id uuid;
    v_delivered_at timestamptz;
    v_order_source text;
    v_customer_id uuid;
    v_amount numeric;
    v_customer_type text;
    v_ok boolean;
    v_deposits_paid numeric := 0;
    v_net_ar numeric := 0;
    v_err text;
    v_reason text;
    v_wh uuid;
begin
    v_actor := auth.uid();
    v_order_source := '';
    if auth.role() <> 'service_role' then
      if not public.is_staff() then
        raise exception 'not allowed';
      end if;
    end if;
    select * into v_order from public.orders o where o.id = p_order_id for update;
    if not found then raise exception 'order not found'; end if;
    v_order_data := coalesce(v_order.data, '{}'::jsonb);
    v_order_source := coalesce(nullif(v_order_data->>'orderSource',''), nullif(p_updated_data->>'orderSource',''), '');
    v_wh := coalesce(v_order.warehouse_id, nullif(v_order_data->>'warehouseId','')::uuid);
    if v_wh is null then raise exception 'warehouse_id required'; end if;
    if p_warehouse_id is not null and p_warehouse_id <> v_wh then raise exception 'warehouse_id mismatch'; end if;
    if auth.role() <> 'service_role' then
      if v_order_source = 'in_store' then
        if not public.has_admin_permission('orders.markPaid') then raise exception 'not allowed'; end if;
      else
        if not (public.has_admin_permission('orders.updateStatus.all') or public.has_admin_permission('orders.updateStatus.delivery')) then raise exception 'not allowed'; end if;
        if public.has_admin_permission('orders.updateStatus.delivery') and not public.has_admin_permission('orders.updateStatus.all') then
          if (v_order_data->>'assignedDeliveryUserId') is distinct from v_actor::text then raise exception 'not allowed'; end if;
        end if;
      end if;
    end if;

    v_customer_id := coalesce(nullif(v_order_data->>'customerId','')::uuid, nullif(p_updated_data->>'customerId','')::uuid, (select c.auth_user_id from public.customers c where c.auth_user_id = v_order.customer_auth_user_id limit 1));
    v_amount := coalesce(nullif((v_order_data->>'total')::numeric, null), nullif((p_updated_data->>'total')::numeric, null), 0);
    if v_customer_id is not null then
      select c.customer_type into v_customer_type from public.customers c where c.auth_user_id = v_customer_id;
    end if;
    if v_customer_type = 'wholesale' then
      v_delivered_at := now();
      select coalesce(sum(p.amount), 0) into v_deposits_paid from public.payments p where p.reference_table = 'orders' and p.reference_id = p_order_id::text and p.direction = 'in' and p.occurred_at < v_delivered_at;
      v_deposits_paid := least(greatest(coalesce(v_amount, 0), 0), greatest(coalesce(v_deposits_paid, 0), 0));
      v_net_ar := greatest(0, coalesce(v_amount, 0) - v_deposits_paid);
      select public.check_customer_credit_limit(v_customer_id, v_net_ar) into v_ok;
      if not v_ok then raise exception 'CREDIT_LIMIT_EXCEEDED'; end if;
    end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' then p_items := '[]'::jsonb; end if;
    v_items_all := p_items;
    v_promos := coalesce(v_order_data->'promotionLines', '[]'::jsonb);
    v_is_cod := public._is_cod_delivery_order(v_order_data, v_order.delivery_zone_id);
    if v_is_cod then
      v_driver_id := nullif(coalesce(p_updated_data->>'deliveredBy', p_updated_data->>'assignedDeliveryUserId', v_order_data->>'deliveredBy', v_order_data->>'assignedDeliveryUserId'),'')::uuid;
      if v_driver_id is null then raise exception 'delivery_driver_required'; end if;
    end if;
    if jsonb_typeof(v_promos) = 'array' and jsonb_array_length(v_promos) > 0 then
      if nullif(btrim(coalesce(v_order_data->>'appliedCouponCode', '')), '') is not null then raise exception 'promotion_coupon_conflict'; end if;
      if coalesce(nullif((v_order_data->>'pointsRedeemedValue')::numeric, null), 0) > 0 then raise exception 'promotion_points_conflict'; end if;
      for v_line in select value from jsonb_array_elements(v_promos)
      loop
        v_snapshot := public._compute_promotion_snapshot((v_line->>'promotionId')::uuid, null, v_wh, coalesce(nullif((v_line->>'bundleQty')::numeric, null), 1), null, true);
        v_snapshot := v_snapshot || jsonb_build_object('promotionLineId', v_line->>'promotionLineId');
        v_promos_fixed := v_promos_fixed || v_snapshot;
        for v_item in select value from jsonb_array_elements(coalesce(v_snapshot->'items','[]'::jsonb))
        loop
          v_items_all := v_items_all || jsonb_build_object('itemId', v_item->>'itemId', 'quantity', coalesce(nullif((v_item->>'quantity')::numeric, null), 0));
        end loop;
        insert into public.promotion_usage(promotion_id, promotion_line_id, order_id, bundle_qty, channel, warehouse_id, snapshot, created_by)
        values ((v_snapshot->>'promotionId')::uuid, (v_snapshot->>'promotionLineId')::uuid, p_order_id, coalesce(nullif((v_snapshot->>'bundleQty')::numeric, null), 1), 'in_store', v_wh, v_snapshot, auth.uid())
        on conflict (promotion_line_id) do nothing;
      end loop;
      v_items_all := public._merge_stock_items(v_items_all);
    else
      v_items_all := public._merge_stock_items(v_items_all);
    end if;

    if jsonb_array_length(v_items_all) = 0 then
      v_items_all := public._extract_stock_items_from_order_data(v_order_data);
    end if;
    if jsonb_array_length(v_items_all) = 0 then
      raise exception 'no deliverable items';
    end if;

    if exists (select 1 from public.inventory_movements im where im.reference_table = 'orders' and im.reference_id = p_order_id::text and im.movement_type = 'sale_out') then
      update public.orders set status = 'delivered', data = p_updated_data, updated_at = now() where id = p_order_id;
      return;
    end if;

    begin
      perform public.deduct_stock_on_delivery_v2(p_order_id, v_items_all, v_wh);
    exception when others then
      v_err := coalesce(sqlerrm, '');
      if v_err = 'SELLING_BELOW_COST_NOT_ALLOWED' then raise; end if;
      if v_err ilike '%batch not released or recalled%' then raise exception 'BATCH_NOT_RELEASED'; end if;
      if v_err = 'BATCH_EXPIRED' then raise exception 'NO_VALID_BATCH'; end if;
      if v_err ilike '%insufficient%' or v_err ilike '%INSUFFICIENT%' then
        v_reason := null;
        for v_item in select value from jsonb_array_elements(coalesce(v_items_all,'[]'::jsonb))
        loop
          v_reason := public._resolve_batch_sale_failure_reason(coalesce(nullif(v_item->>'itemId',''), nullif(v_item->>'id','')), v_wh, coalesce(nullif((v_item->>'quantity')::numeric, null), coalesce(nullif((v_item->>'qty')::numeric, null), 0)));
          if v_reason is not null then raise exception '%', v_reason; end if;
        end loop;
        raise exception 'INSUFFICIENT_BATCH_QUANTITY';
      end if;
      raise;
    end;

    v_final_data := coalesce(p_updated_data, v_order_data);
    if jsonb_array_length(v_promos_fixed) > 0 then
      v_final_data := jsonb_set(v_final_data, '{promotionLines}', v_promos_fixed, true);
    end if;
    if v_is_cod then
      v_final_data := v_final_data - 'paidAt';
      v_driver_id := nullif(v_final_data->>'deliveredBy','')::uuid;
      if v_driver_id is null then v_driver_id := nullif(v_final_data->>'assignedDeliveryUserId','')::uuid; end if;
      if v_driver_id is not null then
        v_delivered_at := coalesce(nullif(v_final_data->>'deliveredAt','')::timestamptz, now());
        perform public.cod_post_delivery(p_order_id, v_driver_id, v_delivered_at);
      end if;
    end if;
    update public.orders set status = 'delivered', data = v_final_data, updated_at = now() where id = p_order_id;
end;
$$;
revoke all on function public.confirm_order_delivery(uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.confirm_order_delivery(uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.confirm_order_delivery(uuid, jsonb, jsonb, uuid) to authenticated;

create or replace function public.trg_set_order_fx()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base text;
  v_currency text;
  v_rate numeric;
  v_total numeric;
  v_is_posted boolean := false;
begin
  v_base := public.get_base_currency();
  if tg_op = 'UPDATE' then
    v_is_posted := exists (select 1 from public.journal_entries je where je.source_table = 'orders' and je.source_id = old.id::text and je.source_event in ('invoiced','delivered') limit 1);
    if v_is_posted then
      if new.data is distinct from old.data or new.currency is distinct from old.currency or new.fx_rate is distinct from old.fx_rate or new.base_total is distinct from old.base_total then
        raise exception 'posted_order_immutable';
      end if;
      return new;
    end if;
    if coalesce(old.fx_locked, true) then
      if new.currency is distinct from old.currency or new.fx_rate is distinct from old.fx_rate then
        raise exception 'fx_locked';
      end if;
    end if;
  end if;
  v_currency := upper(nullif(btrim(coalesce(new.currency, new.data->>'currency', '')), ''));
  if v_currency is null then v_currency := v_base; end if;
  new.currency := v_currency;
  v_rate := public.get_fx_rate(new.currency, current_date, 'operational');
  if v_rate is null then raise exception 'fx rate missing for currency %', new.currency; end if;
  new.fx_rate := v_rate;
  v_total := 0;
  begin v_total := nullif((new.data->>'total')::numeric, null); exception when others then v_total := 0; end;
  new.base_total := coalesce(v_total, 0) * coalesce(new.fx_rate, 1);
  return new;
end;
$$;
drop trigger if exists trg_set_order_fx on public.orders;
create trigger trg_set_order_fx before insert or update on public.orders for each row execute function public.trg_set_order_fx();

create or replace function public.trg_orders_forbid_posted_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_posted boolean := false;
begin
  v_is_posted := exists (select 1 from public.journal_entries je where je.source_table = 'orders' and je.source_id = old.id::text and je.source_event in ('invoiced','delivered') limit 1);
  if v_is_posted then
    if new.data is distinct from old.data or new.currency is distinct from old.currency or new.fx_rate is distinct from old.fx_rate or new.base_total is distinct from old.base_total or new.warehouse_id is distinct from old.warehouse_id then
      raise exception 'posted_order_immutable';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_orders_forbid_posted_updates on public.orders;
create trigger trg_orders_forbid_posted_updates before update on public.orders for each row execute function public.trg_orders_forbid_posted_updates();

create or replace function public.normalize_invoice_snapshot(p_snapshot jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_arr jsonb;
  v_idx int := 0;
  v_len int := 0;
  v_unit_type text;
  v_q numeric;
  v_price numeric;
  v_line_total numeric;
begin
  if p_snapshot is null then
    return '{}'::jsonb;
  end if;
  v_arr := coalesce(p_snapshot->'items','[]'::jsonb);
  v_len := jsonb_array_length(v_arr);
  while v_idx < v_len loop
    select v_arr->v_idx into v_item;
    v_unit_type := coalesce(v_item->>'unitType','piece');
    if v_unit_type in ('kg','gram') then
      v_q := coalesce(nullif((v_item->>'weight')::numeric, null), coalesce(nullif((v_item->>'quantity')::numeric, null), 0));
      if v_unit_type = 'gram' and nullif((v_item->>'pricePerUnit')::numeric, null) is not null then
        v_price := (v_item->>'pricePerUnit')::numeric / 1000;
      else
        v_price := coalesce(nullif((v_item->>'price')::numeric, null), 0);
      end if;
    else
      v_q := coalesce(nullif((v_item->>'quantity')::numeric, null), 0);
      v_price := coalesce(nullif((v_item->>'price')::numeric, null), 0);
    end if;
    v_line_total := coalesce(v_price,0) * coalesce(v_q,0);
    v_item := jsonb_set(v_item, '{line_total}', to_jsonb(public._money_round(v_line_total)), true);
    v_items := v_items || jsonb_build_array(v_item);
    v_idx := v_idx + 1;
  end loop;
  return jsonb_set(p_snapshot, '{items}', v_items, true);
end;
$$;

create or replace function public.trg_validate_invoice_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_snap jsonb;
begin
  v_status := lower(coalesce(new.status,''));
  if v_status in ('issued','delivered','posted') then
    v_snap := coalesce(new.data->'invoiceSnapshot', '{}'::jsonb);
    if jsonb_typeof(v_snap) <> 'object' then
      raise exception 'invoice_snapshot_required';
    end if;
    if not (v_snap ? 'currency') or not (v_snap ? 'fxRate') or not (v_snap ? 'baseCurrency') then
      raise exception 'invoice_snapshot_fields_missing';
    end if;
    if jsonb_typeof(v_snap->'items') <> 'array' then
      raise exception 'invoice_snapshot_items_missing';
    end if;
    v_snap := public.normalize_invoice_snapshot(v_snap);
    new.data := jsonb_set(coalesce(new.data,'{}'::jsonb), '{invoiceSnapshot}', v_snap, true);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_validate_invoice_snapshot on public.orders;
create trigger trg_validate_invoice_snapshot before insert or update on public.orders for each row execute function public.trg_validate_invoice_snapshot();

do $$
begin
  if to_regclass('public.orders') is not null then
    alter table public.orders drop constraint if exists orders_invoice_snapshot_required;
    alter table public.orders add constraint orders_invoice_snapshot_required check (
      case
        when lower(coalesce(status,'')) in ('issued','delivered','posted')
          then coalesce(data ? 'invoiceSnapshot', false)
        else true
      end
    ) not valid;
  end if;
end $$;

notify pgrst, 'reload schema';
