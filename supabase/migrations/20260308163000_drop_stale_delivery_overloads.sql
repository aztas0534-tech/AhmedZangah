-- =============================================================================
-- CRITICAL FIX: Drop ALL stale overloads of confirm_order_delivery and
-- deduct_stock_on_delivery_v2 that are left over from older migrations.
--
-- ROOT CAUSE: Production has these ghost overloads that PostgREST may call
-- instead of the intended 4-arg version, causing "column data does not exist":
--   - confirm_order_delivery(uuid, jsonb, jsonb)  [3-arg, stale body]
--   - deduct_stock_on_delivery_v2(uuid, jsonb)    [2-arg, no warehouse]
--   - deduct_stock_on_delivery_v2(uuid, uuid)     [stale wrapper]
--   - deduct_stock_on_delivery_v2(jsonb)           [no-op payload stub]
-- =============================================================================

-- 1. Drop stale confirm_order_delivery overloads
drop function if exists public.confirm_order_delivery(uuid, jsonb, jsonb);                     -- stale 3-arg

-- 2. Drop stale deduct_stock_on_delivery_v2 overloads
drop function if exists public.deduct_stock_on_delivery_v2(p_payload jsonb);                   -- no-op stub
drop function if exists public.deduct_stock_on_delivery_v2(uuid, uuid);                        -- stale 2-arg wrapper
drop function if exists public.deduct_stock_on_delivery_v2(uuid, jsonb);                       -- old 2-arg, no warehouse

-- 3. Verify remaining overloads are correct (these should survive):
--    confirm_order_delivery(uuid, jsonb, jsonb, uuid)    → main 4-arg function
--    confirm_order_delivery(jsonb)                        → wrapper
--    confirm_order_delivery_with_credit(uuid, jsonb, jsonb, uuid)
--    confirm_order_delivery_with_credit(jsonb)
--    deduct_stock_on_delivery_v2(uuid, jsonb, uuid)       → main 3-arg
--    deduct_stock_on_delivery_v2(jsonb, uuid, uuid)       → swapped-arg wrapper

-- 4. Clean up diagnostic functions
drop function if exists public._diag_delivery_chain(uuid);

-- 5. Reload PostgREST schema cache
select pg_sleep(0.5);
notify pgrst, 'reload schema';
