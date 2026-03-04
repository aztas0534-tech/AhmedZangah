-- Convert auth helper functions to plpgsql to prevent inlining ambiguities with PostgREST CTEs

create or replace function public.is_admin()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = auth.uid()
      and au.is_active = true
  );
end;
$$;

create or replace function public.is_owner()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = auth.uid()
      and au.is_active = true
      and au.role = 'owner'
  );
end;
$$;

create or replace function public.can_manage_expenses()
returns boolean
language plpgsql
security definer
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
        or ('expenses.manage' = any(coalesce(au.permissions, '{}'::text[])))
      )
  );
end;
$$;

create or replace function public.can_view_accounting_reports()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.has_admin_permission('accounting.view');
end;
$$;

notify pgrst, 'reload schema';
