-- Re-enable the immutability triggers that were disabled in the previous migration
-- This must be in a separate transaction to avoid pending trigger events error
alter table public.orders enable trigger trg_set_order_fx;
alter table public.orders enable trigger trg_orders_forbid_posted_updates;

notify pgrst, 'reload schema';
