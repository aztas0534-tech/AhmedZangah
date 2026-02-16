
-- Seed Sales Data for Audit
-- Bypassing RPCs to ensure we have 'delivered' orders with COGS

BEGIN;

-- 1. Setup Context
-- Get Warehouse
DO $$
DECLARE
    v_warehouse_id uuid;
    v_item_id text := 'smoke-audit-item-1';
    v_order_id uuid := '99999999-9999-4999-9999-999999999999'::uuid;
    v_zone_id uuid := '11111111-1111-4111-8111-111111111111'::uuid;
    v_base_currency text;
    v_uom_id uuid;
BEGIN
    SELECT id INTO v_warehouse_id FROM public.warehouses WHERE is_active = true LIMIT 1;
    v_base_currency := public.get_base_currency();

    -- Clean up previous run
    DELETE FROM public.order_item_cogs WHERE order_id = v_order_id;
    DELETE FROM public.inventory_movements WHERE reference_id = v_order_id::text;
    DELETE FROM public.orders WHERE id = v_order_id;

    -- 2. Ensure Item Exists
    -- 2. Ensure Item Exists
    INSERT INTO public.menu_items (id, name, price, cost_price, status)
    VALUES (v_item_id, '{"en": "Audit Item", "ar": "منتج فحص"}'::jsonb, 100, 10, 'active')
    ON CONFLICT (id) DO UPDATE SET price = 100, cost_price = 10;

    -- 2b. Ensure UOM Exists
    SELECT id INTO v_uom_id FROM public.uom WHERE lower(name) = 'piece' LIMIT 1;
    IF v_uom_id IS NULL THEN
        INSERT INTO public.uom (name, code) VALUES ('Piece', 'piece') RETURNING id INTO v_uom_id;
    END IF;

    INSERT INTO public.item_uom (item_id, base_uom_id, purchase_uom_id, sales_uom_id)
    VALUES (v_item_id, v_uom_id, v_uom_id, v_uom_id)
    ON CONFLICT (item_id) DO NOTHING;

    -- 3. Insert Order (Delivered)
    -- We disable triggers to avoid logic conflicts during manual seed
    -- ALTER TABLE public.orders DISABLE TRIGGER ALL; -- Requires superuser, which we have in docker exec

    INSERT INTO public.orders (
        id, 
        warehouse_id, 
        delivery_zone_id, 
        status, 
        total, 
        base_total, 
        subtotal, 
        discount, 
        tax, 
        delivery_fee, 
        currency, 
        fx_rate, 
        data, 
        created_at, 
        updated_at
    )
    VALUES (
        v_order_id,
        v_warehouse_id,
        v_zone_id,
        'delivered',
        100, -- Total Foreign
        100, -- Base Total (Assuming Base Currency)
        100, -- Subtotal
        0,   -- Discount
        0,   -- Tax
        0,   -- Delivery Fee
        v_base_currency,
        1.0,
        jsonb_build_object(
            'items', jsonb_build_array(
                jsonb_build_object(
                    'itemId', v_item_id,
                    'quantity', 1,
                    'price', 100,
                    'costPrice', 10,
                    'unit', 'piece'
                )
            ),
            'orderSource', 'in_store',
            'paymentMethod', 'cash',
            'paidAt', now(),
            'deliveredAt', now(),
            'currency', v_base_currency,
            'fxRate', 1.0,
            'total', 100,
            'subtotal', 100,
            'status', 'delivered',
            'invoiceSnapshot', jsonb_build_object(
                'currency', v_base_currency,
                'fxRate', 1.0,
                'baseCurrency', v_base_currency,
                'total', 100,
                'subtotal', 100,
                'discountAmount', 0,
                'taxAmount', 0,
                'deliveryFee', 0,
                'items', jsonb_build_array(
                    jsonb_build_object(
                        'itemId', v_item_id,
                        'quantity', 1,
                        'price', 100,
                        'costPrice', 10,
                        'unit', 'piece',
                        'unitType', 'piece'
                    )
                )
            )
        ),
        now(),
        now()
    );

    -- ALTER TABLE public.orders ENABLE TRIGGER ALL;

    -- 2c. Ensure Batch Exists
    INSERT INTO public.batches (
        id, 
        item_id, 
        warehouse_id, 
        batch_code, 
        quantity_received, 
        quantity_consumed, 
        unit_cost, 
        status, 
        qc_status,
        expiry_date
    )
    VALUES (
        gen_random_uuid(), -- We can generate one or use a var. Let's use a var if we declared it, or just subquery/returning.
        v_item_id,
        v_warehouse_id,
        'SEED-BATCH-001',
        100,
        0,
        10,
        'active',
        'released',
        now() + interval '1 year'
    )
    ON CONFLICT DO NOTHING; -- If batch code unique? Likely unique.

    -- Get a valid batch id
    DECLARE
        v_batch_id uuid;
    BEGIN
        SELECT id INTO v_batch_id FROM public.batches WHERE item_id = v_item_id AND warehouse_id = v_warehouse_id LIMIT 1;

        -- 4. Insert COGS (Crucial for Profit Report)
        INSERT INTO public.order_item_cogs (
            order_id,
            item_id,
            quantity,
            unit_cost,
            total_cost
        )
        VALUES (
            v_order_id,
            v_item_id,
            1,
            10,
            10
        );

        -- 5. Insert Inventory Movement (For Verification)
        INSERT INTO public.inventory_movements (
            item_id,
            movement_type,
            quantity,
            unit_cost,
            total_cost,
            reference_table,
            reference_id,
            occurred_at,
            batch_id,
            warehouse_id
        )
        VALUES (
            v_item_id,
            'sale_out',
            1,
            10,
            10,
            'orders',
            v_order_id::text,
            now(),
            v_batch_id,
            v_warehouse_id
        );
    END;

    RAISE NOTICE 'Seeded Order %', v_order_id;
END $$;

COMMIT;
