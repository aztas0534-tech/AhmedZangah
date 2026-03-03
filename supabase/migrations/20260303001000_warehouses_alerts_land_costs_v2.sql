-- Migration: تنبيهات انخفاض المخزون وتكاليف النقل
-- التاريخ: 2026-03-03
-- الوصف: إضافة minimum_stock_level, shipping_cost, system_alerts

-- ==========================================
-- 1. إضافة columns جديدة
-- ==========================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'stock_management' AND column_name = 'minimum_stock_level'
  ) THEN
    ALTER TABLE public.stock_management ADD COLUMN minimum_stock_level NUMERIC DEFAULT 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'warehouse_transfers' AND column_name = 'shipping_cost'
  ) THEN
    ALTER TABLE public.warehouse_transfers ADD COLUMN shipping_cost NUMERIC DEFAULT 0;
  END IF;
END $$;

-- ==========================================
-- 2. إنشاء جدول التنبيهات System Alerts
-- ==========================================
CREATE TABLE IF NOT EXISTS public.system_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL CHECK (type IN ('low_stock', 'expiry', 'system')),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  reference_id TEXT, -- e.g. item_id, batch_id
  warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE,
  is_read BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  read_at TIMESTAMPTZ,
  read_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_system_alerts_type ON public.system_alerts(type);
CREATE INDEX IF NOT EXISTS idx_system_alerts_warehouse ON public.system_alerts(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_system_alerts_is_read ON public.system_alerts(is_read);

-- RLS
ALTER TABLE public.system_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS alerts_select ON public.system_alerts;
CREATE POLICY alerts_select ON public.system_alerts
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.admin_users WHERE auth_user_id = auth.uid() AND is_active = true)
  );

DROP POLICY IF EXISTS alerts_manage ON public.system_alerts;
CREATE POLICY alerts_manage ON public.system_alerts
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.admin_users WHERE auth_user_id = auth.uid() AND is_active = true)
  );

-- ==========================================
-- 3. Trigger لتوليد تنبيهات انخفاض المخزون تلقائياً
-- ==========================================
CREATE OR REPLACE FUNCTION public.check_minimum_stock_level()
RETURNS TRIGGER AS $$
DECLARE
  v_item_name TEXT;
  v_warehouse_name TEXT;
  v_existing_alert UUID;
BEGIN
  -- We only fire alerts if available_quantity drops below or equals minimum_stock_level
  -- And minimum_stock_level is actually set > 0
  IF NEW.minimum_stock_level > 0 AND NEW.available_quantity <= NEW.minimum_stock_level THEN
    -- Prevent spamming by checking if an unread alert already exists for this item/warehouse
    SELECT id INTO v_existing_alert
    FROM public.system_alerts
    WHERE type = 'low_stock' 
      AND reference_id = NEW.item_id::text
      AND warehouse_id = NEW.warehouse_id
      AND is_read = false
    LIMIT 1;

    IF v_existing_alert IS NULL THEN
      -- Get Names for better message
      SELECT name->>'ar' INTO v_item_name FROM public.menu_items WHERE id = NEW.item_id::text;
      SELECT name INTO v_warehouse_name FROM public.warehouses WHERE id = NEW.warehouse_id;

      INSERT INTO public.system_alerts (type, title, message, reference_id, warehouse_id)
      VALUES (
        'low_stock',
        'انخفاض المخزون',
        format('الصنف "%s" وصل للحد الأدنى في مخزن "%s". الكمية المتوفرة: %s, الحد الأدنى: %s', 
               COALESCE(v_item_name, NEW.item_id::text), 
               COALESCE(v_warehouse_name, 'غير معروف'), 
               NEW.available_quantity, 
               NEW.minimum_stock_level),
        NEW.item_id::text,
        NEW.warehouse_id
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_check_minimum_stock ON public.stock_management;
CREATE TRIGGER trg_check_minimum_stock
  AFTER UPDATE OF available_quantity, minimum_stock_level ON public.stock_management
  FOR EACH ROW
  EXECUTE FUNCTION public.check_minimum_stock_level();

-- ==========================================
-- 4. تعديل دالة نقل المخازن لتشمل تكلفة النقل Pro-Rata
-- ==========================================
CREATE OR REPLACE FUNCTION public.complete_warehouse_transfer(
  p_transfer_id UUID
) RETURNS VOID AS $$
DECLARE
  v_item RECORD;
  v_from_warehouse UUID;
  v_to_warehouse UUID;
  v_transfer_date DATE;
  v_shipping_cost NUMERIC;
  v_total_transfer_qty NUMERIC := 0;
  v_unit_shipping_cost NUMERIC := 0;
  v_sm_from record;
  v_is_food boolean;
  v_reserved_batches jsonb;
  v_remaining numeric;
  v_batch record;
  v_batch_reserved numeric;
  v_free numeric;
  v_alloc numeric;
  v_unit_cost numeric;
  v_movement_out uuid;
  v_movement_in uuid;
BEGIN
  -- الحصول على معلومات النقل
  SELECT from_warehouse_id, to_warehouse_id, transfer_date, COALESCE(shipping_cost, 0)
  INTO v_from_warehouse, v_to_warehouse, v_transfer_date, v_shipping_cost
  FROM public.warehouse_transfers 
  WHERE id = p_transfer_id AND status = 'pending';
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transfer not found or not pending';
  END IF;

  -- حساب إجمالي الكميات المنقولة لتوزيع تكلفة الشحن عليها
  IF v_shipping_cost > 0 THEN
    SELECT SUM(quantity) INTO v_total_transfer_qty 
    FROM public.warehouse_transfer_items 
    WHERE transfer_id = p_transfer_id;

    IF v_total_transfer_qty > 0 THEN
      v_unit_shipping_cost := v_shipping_cost / v_total_transfer_qty;
    END IF;
  END IF;
  
  -- نقل الأصناف
  FOR v_item IN 
    SELECT id, item_id, quantity, batch_id
    FROM public.warehouse_transfer_items 
    WHERE transfer_id = p_transfer_id
  LOOP
    select *
    into v_sm_from
    from public.stock_management sm
    where sm.item_id = v_item.item_id
      and sm.warehouse_id = v_from_warehouse
    for update;

    if not found then
      raise exception 'Stock record not found for item % in source warehouse', v_item.item_id;
    end if;

    select coalesce(mi.category = 'food', false)
    into v_is_food
    from public.menu_items mi
    where mi.id = v_item.item_id;

    v_is_food := coalesce(v_is_food, false);

    if coalesce(v_sm_from.available_quantity, 0) + 1e-9 < v_item.quantity then
      raise exception 'Insufficient stock for item % in source warehouse', v_item.item_id;
    end if;
    
    -- خصم من المخزن المصدر
    UPDATE public.stock_management
    SET 
      available_quantity = available_quantity - v_item.quantity,
      last_updated = NOW()
    WHERE item_id = v_item.item_id 
      AND warehouse_id = v_from_warehouse;
    
    -- إضافة للمخزن الوجهة
    INSERT INTO public.stock_management (id, item_id, warehouse_id, available_quantity, unit, reserved_quantity, last_updated)
    SELECT 
      gen_random_uuid(),
      v_item.item_id,
      v_to_warehouse,
      v_item.quantity,
      sm.unit,
      0,
      NOW()
    FROM public.stock_management sm
    WHERE sm.item_id = v_item.item_id AND sm.warehouse_id = v_from_warehouse
    LIMIT 1
    ON CONFLICT (item_id, warehouse_id) 
    DO UPDATE SET 
      available_quantity = public.stock_management.available_quantity + v_item.quantity,
      last_updated = NOW();
    
    if not v_is_food then
      -- تسجيل حركة الخروج بالتكلفة الأصلية
      INSERT INTO public.inventory_movements (
        id, item_id, movement_type, quantity, unit_cost, total_cost,
        reference_table, reference_id, occurred_at, created_by, created_at, warehouse_id, data
      )
      VALUES (
        gen_random_uuid(),
        v_item.item_id,
        'adjust_out',
        v_item.quantity,
        COALESCE(v_sm_from.avg_cost, 0),
        COALESCE(v_sm_from.avg_cost, 0) * v_item.quantity,
        'warehouse_transfers',
        p_transfer_id::text,
        v_transfer_date::timestamptz,
        auth.uid(),
        NOW(),
        v_from_warehouse,
        jsonb_build_object('warehouseId', v_from_warehouse, 'toWarehouseId', v_to_warehouse)
      )
      returning id into v_movement_out;

      -- تسجيل الدخول مع إضافة الكلفة الإضافية للشحن
      INSERT INTO public.inventory_movements (
        id, item_id, movement_type, quantity, unit_cost, total_cost,
        reference_table, reference_id, occurred_at, created_by, created_at, warehouse_id, data
      )
      VALUES (
        gen_random_uuid(),
        v_item.item_id,
        'adjust_in',
        v_item.quantity,
        COALESCE(v_sm_from.avg_cost, 0) + v_unit_shipping_cost,
        (COALESCE(v_sm_from.avg_cost, 0) + v_unit_shipping_cost) * v_item.quantity,
        'warehouse_transfers',
        p_transfer_id::text,
        v_transfer_date::timestamptz,
        auth.uid(),
        NOW(),
        v_to_warehouse,
        jsonb_build_object('warehouseId', v_to_warehouse, 'fromWarehouseId', v_from_warehouse, 'shippingCostApplied', v_unit_shipping_cost * v_item.quantity)
      )
      returning id into v_movement_in;
      
      -- Recalculate average cost for non-food item
      PERFORM public.post_inventory_movement(v_movement_in);
    else
      v_reserved_batches := coalesce(v_sm_from.data->'reservedBatches', '{}'::jsonb);
      v_remaining := v_item.quantity;

      if v_item.batch_id is not null then
        select im.unit_cost
        into v_unit_cost
        from public.inventory_movements im
        where im.batch_id = v_item.batch_id
          and im.movement_type = 'purchase_in'
        order by im.occurred_at asc
        limit 1;

        v_unit_cost := coalesce(v_unit_cost, v_sm_from.avg_cost, 0);

        select
          coalesce(sum(coalesce(nullif(x->>'qty','')::numeric, 0)), 0)
        into v_batch_reserved
        from jsonb_array_elements(
          case
            when jsonb_typeof(v_reserved_batches -> (v_item.batch_id::text)) = 'array' then (v_reserved_batches -> (v_item.batch_id::text))
            when jsonb_typeof(v_reserved_batches -> (v_item.batch_id::text)) = 'object' then jsonb_build_array(v_reserved_batches -> (v_item.batch_id::text))
            when jsonb_typeof(v_reserved_batches -> (v_item.batch_id::text)) = 'number' then jsonb_build_array(jsonb_build_object('qty', (v_reserved_batches -> (v_item.batch_id::text))))
            else '[]'::jsonb
          end
        ) as x;

        select greatest(coalesce(b.remaining_qty, 0) - coalesce(v_batch_reserved, 0), 0)
        into v_free
        from public.v_food_batch_balances b
        where b.item_id::text = v_item.item_id
          and b.batch_id = v_item.batch_id
          and b.warehouse_id = v_from_warehouse;

        if coalesce(v_free, 0) + 1e-9 < v_item.quantity then
          raise exception 'Insufficient non-reserved batch stock for item % batch % in source warehouse', v_item.item_id, v_item.batch_id;
        end if;

        insert into public.inventory_movements (
          id, item_id, movement_type, quantity, unit_cost, total_cost,
          reference_table, reference_id, occurred_at, created_by, created_at, warehouse_id, data, batch_id
        )
        values (
          gen_random_uuid(),
          v_item.item_id,
          'adjust_out',
          v_item.quantity,
          v_unit_cost,
          v_unit_cost * v_item.quantity,
          'warehouse_transfers',
          p_transfer_id::text,
          v_transfer_date::timestamptz,
          auth.uid(),
          now(),
          v_from_warehouse,
          jsonb_build_object('warehouseId', v_from_warehouse, 'toWarehouseId', v_to_warehouse, 'batchId', v_item.batch_id),
          v_item.batch_id
        )
        returning id into v_movement_out;

        insert into public.inventory_movements (
          id, item_id, movement_type, quantity, unit_cost, total_cost,
          reference_table, reference_id, occurred_at, created_by, created_at, warehouse_id, data, batch_id
        )
        values (
          gen_random_uuid(),
          v_item.item_id,
          'adjust_in',
          v_item.quantity,
          v_unit_cost + v_unit_shipping_cost,
          (v_unit_cost + v_unit_shipping_cost) * v_item.quantity,
          'warehouse_transfers',
          p_transfer_id::text,
          v_transfer_date::timestamptz,
          auth.uid(),
          now(),
          v_to_warehouse,
          jsonb_build_object('warehouseId', v_to_warehouse, 'fromWarehouseId', v_from_warehouse, 'batchId', v_item.batch_id, 'shippingCostApplied', v_unit_shipping_cost * v_item.quantity),
          v_item.batch_id
        )
        returning id into v_movement_in;
        
        -- Also update destination batch unit_cost if shipped cost is added (approximate standard logic would create new batch/transfer batch ownership with new val)
        -- Since batches table relates to warehouse explicitly, transferring food batches requires either updating the batch warehouse OR creating a new batch
        -- Currently we don't transfer the exact `batches` table row, we rely on inventory_movements. This implies a limitation in batch tracking across warehouses unless explicitly handled.
        -- For simplicity, movement record retains the new higher cost.
        PERFORM public.post_inventory_movement(v_movement_in);
      else
        for v_batch in
          select
            b.batch_id,
            b.expiry_date,
            b.remaining_qty
          from public.v_food_batch_balances b
          where b.item_id::text = v_item.item_id
            and b.warehouse_id = v_from_warehouse
            and b.batch_id is not null
            and b.expiry_date is not null
            and b.expiry_date >= current_date
            and coalesce(b.remaining_qty, 0) > 0
          order by b.expiry_date asc, b.batch_id asc
        loop
          if v_remaining <= 0 then
            exit;
          end if;

          select
            coalesce(sum(coalesce(nullif(x->>'qty','')::numeric, 0)), 0)
          into v_batch_reserved
          from jsonb_array_elements(
            case
              when jsonb_typeof(v_reserved_batches -> (v_batch.batch_id::text)) = 'array' then (v_reserved_batches -> (v_batch.batch_id::text))
              when jsonb_typeof(v_reserved_batches -> (v_batch.batch_id::text)) = 'object' then jsonb_build_array(v_reserved_batches -> (v_batch.batch_id::text))
              when jsonb_typeof(v_reserved_batches -> (v_batch.batch_id::text)) = 'number' then jsonb_build_array(jsonb_build_object('qty', (v_reserved_batches -> (v_batch.batch_id::text))))
              else '[]'::jsonb
            end
          ) as x;

          v_free := greatest(coalesce(v_batch.remaining_qty, 0) - coalesce(v_batch_reserved, 0), 0);
          v_alloc := least(v_remaining, v_free);
          if v_alloc <= 0 then
            continue;
          end if;

          select im.unit_cost
          into v_unit_cost
          from public.inventory_movements im
          where im.batch_id = v_batch.batch_id
            and im.movement_type = 'purchase_in'
          order by im.occurred_at asc
          limit 1;

          v_unit_cost := coalesce(v_unit_cost, v_sm_from.avg_cost, 0);

          insert into public.inventory_movements (
            id, item_id, movement_type, quantity, unit_cost, total_cost,
            reference_table, reference_id, occurred_at, created_by, created_at, warehouse_id, data, batch_id
          )
          values (
            gen_random_uuid(),
            v_item.item_id,
            'adjust_out',
            v_alloc,
            v_unit_cost,
            v_unit_cost * v_alloc,
            'warehouse_transfers',
            p_transfer_id::text,
            v_transfer_date::timestamptz,
            auth.uid(),
            now(),
            v_from_warehouse,
            jsonb_build_object('warehouseId', v_from_warehouse, 'toWarehouseId', v_to_warehouse, 'batchId', v_batch.batch_id),
            v_batch.batch_id
          )
          returning id into v_movement_out;

          insert into public.inventory_movements (
            id, item_id, movement_type, quantity, unit_cost, total_cost,
            reference_table, reference_id, occurred_at, created_by, created_at, warehouse_id, data, batch_id
          )
          values (
            gen_random_uuid(),
            v_item.item_id,
            'adjust_in',
            v_alloc,
            v_unit_cost + v_unit_shipping_cost,
            (v_unit_cost + v_unit_shipping_cost) * v_alloc,
            'warehouse_transfers',
            p_transfer_id::text,
            v_transfer_date::timestamptz,
            auth.uid(),
            now(),
            v_to_warehouse,
            jsonb_build_object('warehouseId', v_to_warehouse, 'fromWarehouseId', v_from_warehouse, 'batchId', v_batch.batch_id, 'shippingCostApplied', v_unit_shipping_cost * v_alloc),
            v_batch.batch_id
          )
          returning id into v_movement_in;
          PERFORM public.post_inventory_movement(v_movement_in);

          v_remaining := v_remaining - v_alloc;
        end loop;

        if v_remaining > 0 then
          raise exception 'Insufficient non-expired non-reserved batch stock for item % in source warehouse', v_item.item_id;
        end if;
      end if;
    end if;
    
    -- تحديث الكمية المنقولة
    UPDATE public.warehouse_transfer_items
    SET transferred_quantity = v_item.quantity
    WHERE id = v_item.id;
  END LOOP;
  
  -- تحديث حالة النقل
  UPDATE public.warehouse_transfers
  SET 
    status = 'completed', 
    completed_at = NOW(),
    approved_by = auth.uid()
  WHERE id = p_transfer_id;
  
  -- تسجيل في سجل التدقيق المالي والإداري
  INSERT INTO public.system_audit_log (id, action, module, details, performed_by, performed_at)
  VALUES (
    gen_random_uuid(),
    'warehouse_transfer_completed',
    'inventory',
    format('Completed transfer %s from warehouse %s to %s. Shipping Cost Distributed: %s', p_transfer_id, v_from_warehouse, v_to_warehouse, v_shipping_cost),
    auth.uid()::text,
    NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==========================================
-- 5. تهيئة جدول جرد آخر المدة (للمرحلة القادمة)
-- ==========================================
CREATE TABLE IF NOT EXISTS public.inventory_counts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('draft', 'in_progress', 'completed', 'cancelled')) DEFAULT 'draft',
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  notes TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
