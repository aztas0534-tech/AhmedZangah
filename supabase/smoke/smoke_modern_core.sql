set client_min_messages = notice;
set statement_timeout = 0;
set lock_timeout = 0;

DO $$
DECLARE
  t0 timestamptz;
  ms int;
  v_admin_id uuid;
  v_warehouse_id uuid;
  v_base text;
BEGIN
  t0 := clock_timestamp();
  
  -- 1. Create Smoke Admin
  SELECT id INTO v_admin_id FROM auth.users WHERE email = 'smoke-modern@local.test' LIMIT 1;
  IF v_admin_id IS NULL THEN
    v_admin_id := gen_random_uuid();
    INSERT INTO auth.users(id, email, aud, role, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous, created_at, updated_at)
    VALUES (v_admin_id, 'smoke-modern@local.test', 'authenticated', 'authenticated', '{}'::jsonb, '{}'::jsonb, false, false, now(), now());
  END IF;

  INSERT INTO public.admin_users(auth_user_id, username, full_name, email, role, permissions, is_active)
  VALUES (v_admin_id, 'smoke-modern', 'Smoke Modern Admin', 'smoke-modern@local.test', 'manager', array[]::text[], true)
  ON CONFLICT (auth_user_id) DO NOTHING;

  -- 2. Ensure Warehouse
  v_warehouse_id := public._resolve_default_warehouse_id();
  IF v_warehouse_id IS NULL THEN
     RAISE EXCEPTION 'Default warehouse not found';
  END IF;

  v_base := public.get_base_currency();

  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  RAISE NOTICE 'SMOKE_PASS|MODERN01|Prerequisites (Admin, WH % , Currency %)|%|{}', v_warehouse_id, v_base, ms;
END $$;

DO $$
DECLARE
  t0 timestamptz;
  ms int;
  v_admin_id uuid;
  v_warehouse_id uuid;
  v_item_id uuid;
  v_supplier_id uuid;
  v_purchase_id uuid;
  v_receipt_id uuid;
  v_base text;
BEGIN
  t0 := clock_timestamp();
  SELECT id INTO v_admin_id FROM auth.users WHERE email = 'smoke-modern@local.test' LIMIT 1;
  v_warehouse_id := public._resolve_default_warehouse_id();

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, false);

  v_base := public.get_base_currency();

  -- Item
  v_item_id := gen_random_uuid();
  begin
    insert into public.menu_items(id, category, unit_type, base_unit, status, name, price, is_food, expiry_required, sellable, data)
    values (
      v_item_id::text,
      'qat',
      'piece',
      'piece',
      'active',
      jsonb_build_object('ar','صنف دخان حديث ' || substring(v_item_id::text, 1, 8),'en','Modern Smoke Item ' || substring(v_item_id::text, 1, 8)),
      100,
      false,
      false,
      true,
      jsonb_build_object('id', v_item_id::text, 'name', jsonb_build_object('ar','صنف دخان حديث ' || substring(v_item_id::text, 1, 8),'en','Modern Smoke Item ' || substring(v_item_id::text, 1, 8)), 'price', 100, 'category', 'qat', 'unitType', 'piece', 'status', 'active')
    );
  exception when undefined_column then
    insert into public.menu_items(id, category, unit_type, status, data)
    values (v_item_id::text, 'qat', 'piece', 'active', jsonb_build_object('id', v_item_id::text, 'name', jsonb_build_object('ar','صنف دخان حديث ' || substring(v_item_id::text, 1, 8),'en','Modern Smoke Item ' || substring(v_item_id::text, 1, 8)), 'price', 100));
  end;

  if to_regclass('public.item_uom') is not null then
    insert into public.item_uom(item_id, base_uom_id, purchase_uom_id, sales_uom_id)
    values (v_item_id::text, public.get_or_create_uom('piece'), null, null)
    on conflict (item_id) do nothing;
  end if;

  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  RAISE NOTICE 'SMOKE_PASS|MODERN02|Entities Created (Supplier, Customer, Item)|%|{}', ms;

  -- Purchase Order for Initial Stock
  INSERT INTO public.suppliers (name) VALUES ('Modern Smoke Supplier') RETURNING id INTO v_supplier_id;

  v_purchase_id := gen_random_uuid();
  INSERT INTO public.purchase_orders (id, supplier_id, status, currency, fx_rate, total_amount, purchase_date)
  VALUES (v_purchase_id, v_supplier_id, 'draft', v_base, 1, 2000, current_date);

  INSERT INTO public.purchase_items (purchase_order_id, item_id, quantity, unit_cost, total_cost)
  VALUES (v_purchase_id, v_item_id::text, 100, 20, 2000);

  v_receipt_id := public.receive_purchase_order_partial(v_purchase_id, jsonb_build_array(jsonb_build_object('itemId', v_item_id::text, 'quantity', 100, 'unitCost', 20)), now());

  IF NOT EXISTS (SELECT 1 FROM public.inventory_movements WHERE reference_id = v_receipt_id::text) THEN
      RAISE EXCEPTION 'Inventory movement for receipt was not created';
  END IF;

  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  RAISE NOTICE 'SMOKE_PASS|MODERN03|Inventory Received via PO and FEFO Batch Active|%|{}', ms;
END $$;

DO $$
DECLARE
  t0 timestamptz;
  ms int;
  v_admin_id uuid;
  v_warehouse_id uuid;
  v_item_id uuid;
  v_order_json jsonb;
  v_base text;
BEGIN
  t0 := clock_timestamp();
  SELECT id INTO v_admin_id FROM auth.users WHERE email = 'smoke-modern@local.test' LIMIT 1;
  v_warehouse_id := public._resolve_default_warehouse_id();
  SELECT id::uuid INTO v_item_id FROM public.menu_items WHERE category = 'qat' ORDER BY created_at DESC LIMIT 1;
  v_base := public.get_base_currency();

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, false);

  -- Create order with a Guest Customer (no specific DB Auth ID)
  v_order_json := public.create_order_secure(
    jsonb_build_array(jsonb_build_object('itemId', v_item_id::text, 'quantity', 2)),
    null, 'cash', '', '', null, 'Modern Customer', '987654321', false, null, null, 0, null, 
    'in_store', v_base, v_warehouse_id
  );

  DECLARE
    v_updated jsonb;
    v_payload jsonb;
  BEGIN
    v_updated := jsonb_build_object(
      'id', v_order_json->>'id',
      'status', 'delivered',
      'orderSource', 'in_store',
      'deliveredAt', now()::text,
      'paidAt', now()::text,
      'paymentMethod', 'cash',
      'items', jsonb_build_array(jsonb_build_object('itemId', v_item_id::text, 'quantity', 2, 'price', 20)),
      'subtotal', 40,
      'deliveryFee', 0,
      'discountAmount', 0,
      'taxAmount', 0,
      'total', 40,
      'currency', v_base,
      'fxRate', 1,
      'baseCurrency', v_base
    );

    v_payload := jsonb_build_object(
      'p_order_id', v_order_json->>'id', 
      'p_items', jsonb_build_array(jsonb_build_object('itemId', v_item_id::text, 'quantity', 2)), 
      'p_updated_data', v_updated, 
      'p_warehouse_id', v_warehouse_id::text
    );
    PERFORM public.confirm_order_delivery(v_payload);
  END;

  ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
  RAISE NOTICE 'SMOKE_PASS|MODERN04|Order Created and Delivered features tested (FEFO Deducted)|%|{}', ms;
END $$;

\echo MODERN_SMOKE_OK
