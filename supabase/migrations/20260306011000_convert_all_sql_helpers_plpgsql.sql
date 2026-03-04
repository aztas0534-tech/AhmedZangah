-- Convert ALL remaining LANGUAGE SQL boolean helper functions to plpgsql
-- to prevent PostgreSQL from inlining them into PostgREST CTEs,
-- which causes "column reference id is ambiguous" errors.

-- 1. is_staff
create or replace function public.is_staff()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = auth.uid()
      and au.is_active = true
      and au.role in ('owner', 'manager', 'employee', 'cashier', 'delivery')
  );
end;
$$;

-- 2. can_manage_stock
create or replace function public.can_manage_stock()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = auth.uid()
      and au.is_active = true
      and (
        au.role in ('owner','manager')
        or ('stock.manage' = any(coalesce(au.permissions, '{}'::text[])))
      )
  );
end;
$$;

-- 3. can_manage_orders
create or replace function public.can_manage_orders()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return public.has_admin_permission('orders.markPaid')
      or public.has_admin_permission('orders.updateStatus.all')
      or public.has_admin_permission('orders.createInStore');
end;
$$;

-- 4. can_view_enterprise_financial_reports
create or replace function public.can_view_enterprise_financial_reports()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return public.has_admin_permission('accounting.view')
     or public.has_admin_permission('reports.view');
end;
$$;

-- 5. can_view_reports
create or replace function public.can_view_reports()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return public.has_admin_permission('reports.view') or public.has_admin_permission('accounting.view');
end;
$$;

-- 6. can_view_sales_reports
create or replace function public.can_view_sales_reports()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return public.has_admin_permission('reports.view');
end;
$$;

-- 7. is_owner_or_manager
create or replace function public.is_owner_or_manager()
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = auth.uid()
      and au.is_active = true
      and au.role in ('owner','manager')
  );
end;
$$;

-- 8. is_system_user
create or replace function public.is_system_user(p_auth_user_id uuid)
returns boolean
language plpgsql
stable security definer
set search_path = public
as $$
begin
  return exists(
    select 1
    from public.admin_users au
    where au.auth_user_id = p_auth_user_id
      and au.is_active = true
  );
end;
$$;

notify pgrst, 'reload schema';
