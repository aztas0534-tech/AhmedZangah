-- Re-enable USER triggers on inventory_movements after batch cost repair
alter table public.inventory_movements enable trigger user;

notify pgrst, 'reload schema';
