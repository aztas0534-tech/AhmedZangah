-- Create the base table for Inventory Stocktaking Sessions
create table if not exists public.inventory_counts (
    id uuid primary key default uuid_generate_v4(),
    warehouse_id uuid not null references public.warehouses(id) on delete restrict,
    status text not null check (status in ('draft', 'in_progress', 'completed', 'cancelled')) default 'draft',
    created_by uuid not null references auth.users(id),
    started_at timestamptz,
    completed_at timestamptz,
    notes text,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

-- Enable RLS
alter table public.inventory_counts enable row level security;

create policy "Enable read access for authenticated users" 
on public.inventory_counts for select 
to authenticated using (true);

create policy "Enable all access for authenticated users with valid role" 
on public.inventory_counts for all 
to authenticated 
using (public.can_manage_stock() or (auth.jwt()->>'role' in ('owner', 'manager')));

-- Create items table
create table if not exists public.inventory_count_items (
    id uuid primary key default uuid_generate_v4(),
    count_id uuid not null references public.inventory_counts(id) on delete cascade,
    item_id text not null references public.menu_items(id) on delete restrict,
    expected_quantity numeric(12,4) not null default 0,
    actual_quantity numeric(12,4),
    variance numeric(12,4),
    unit_cost numeric(12,4),
    notes text,
    created_at timestamptz default now(),
    updated_at timestamptz default now(),
    unique(count_id, item_id)
);

-- Enable RLS
alter table public.inventory_count_items enable row level security;

create policy "Enable read access for authenticated users" 
on public.inventory_count_items for select 
to authenticated using (true);

create policy "Enable all access for authenticated users with valid role" 
on public.inventory_count_items for all 
to authenticated 
using (public.can_manage_stock() or (auth.jwt()->>'role' in ('owner', 'manager')));

-- Triggers for updated_at
create trigger set_inventory_counts_updated_at
before update on public.inventory_counts
for each row execute function public.handle_updated_at();

create trigger set_inventory_count_items_updated_at
before update on public.inventory_count_items
for each row execute function public.handle_updated_at();

-- RPC to start a count (fetch current stock)
create or replace function public.start_inventory_count(p_count_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_status text;
    v_warehouse_id uuid;
begin
    if not (public.can_manage_stock() or (auth.jwt()->>'role' in ('owner', 'manager'))) then
        raise exception 'Not authorized to start inventory counts';
    end if;

    select status, warehouse_id into v_status, v_warehouse_id
    from public.inventory_counts
    where id = p_count_id
    for update;

    if v_status is null then
        raise exception 'Count not found';
    end if;

    if v_status != 'draft' then
        raise exception 'Can only start a draft count';
    end if;

    -- Update status
    update public.inventory_counts
    set status = 'in_progress', started_at = now(), updated_at = now()
    where id = p_count_id;

    -- Pre-populate items with expected stock
    insert into public.inventory_count_items (count_id, item_id, expected_quantity, actual_quantity, variance, unit_cost)
    select 
        p_count_id,
        sm.item_id,
        sm.available_quantity,
        null as actual_quantity,
        null as variance,
        (
            select lcl.unit_cost 
            from public.item_cost_layers lcl 
            where lcl.item_id = sm.item_id::text and lcl.warehouse_id = sm.warehouse_id 
              and lcl.remaining_qty > 0 
            order by lcl.created_at asc limit 1
        ) as unit_cost
    from public.stock_management sm
    where sm.warehouse_id = v_warehouse_id;

end;
$$;

-- Grant execution to authenticated
grant execute on function public.start_inventory_count(uuid) to authenticated;

-- RPC to complete a count
create or replace function public.complete_inventory_count(
    p_count_id uuid,
    p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_status text;
    v_warehouse_id uuid;
    v_user_id uuid;
    v_item record;
    v_movement_id uuid;
begin
    v_user_id := auth.uid();
    if not (public.can_manage_stock() or (auth.jwt()->>'role' in ('owner', 'manager'))) then
        raise exception 'Not authorized to complete inventory counts';
    end if;

    select status, warehouse_id into v_status, v_warehouse_id
    from public.inventory_counts
    where id = p_count_id
    for update;

    if v_status is null then
        raise exception 'Count not found';
    end if;

    if v_status != 'in_progress' then
        raise exception 'Can only complete an in-progress count';
    end if;

    -- Mark as completed
    update public.inventory_counts
    set status = 'completed', 
        completed_at = now(), 
        updated_at = now(),
        notes = coalesce(p_notes, notes)
    where id = p_count_id;

    -- Auto-calculate variance for any edited rows before processing
    update public.inventory_count_items
    set variance = actual_quantity - expected_quantity
    where count_id = p_count_id and actual_quantity is not null;

    -- Handle necessary stock adjustments
    for v_item in 
        select id, item_id, expected_quantity, actual_quantity, variance, unit_cost
        from public.inventory_count_items
        where count_id = p_count_id and variance != 0 and actual_quantity is not null
    loop
        if v_item.variance > 0 then
            -- Adjust IN (Found extra stock)
            v_movement_id := public.manage_menu_item_stock(
                p_item_id := v_item.item_id::text,
                p_quantity := abs(v_item.variance),
                p_type := 'adjust_in',
                p_warehouse_id := v_warehouse_id,
                p_reference := 'STOCKTAKE-' || substring(p_count_id::text, 1, 8),
                p_notes := 'فائض جرد آلي',
                p_unit_cost := coalesce(v_item.unit_cost, 0),
                p_created_by := v_user_id
            );
        else
            -- Adjust OUT (Missing stock)
            v_movement_id := public.manage_menu_item_stock(
                p_item_id := v_item.item_id::text,
                p_quantity := abs(v_item.variance),
                p_type := 'adjust_out',
                p_warehouse_id := v_warehouse_id,
                p_reference := 'STOCKTAKE-' || substring(p_count_id::text, 1, 8),
                p_notes := 'عجز جرد آلي',
                p_created_by := v_user_id
            );
        end if;
    end loop;

end;
$$;

-- Grant execution to authenticated
grant execute on function public.complete_inventory_count(uuid, text) to authenticated;

-- Ensure RLS allows the view
notify pgrst, 'reload schema';
