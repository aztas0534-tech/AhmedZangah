-- Grant qc.inspect and qc.release to all current admin_users 
-- who are not 'owner' or 'manager' (since those get it implicitly, but let's just add it to everyone to be safe).

do $$
declare
  v_user record;
  v_perms text[];
begin
  for v_user in 
    select auth_user_id, permissions 
    from public.admin_users 
    where is_active = true
  loop
    v_perms := coalesce(v_user.permissions, array[]::text[]);
    
    if not ('qc.inspect' = any(v_perms)) then
      v_perms := array_append(v_perms, 'qc.inspect');
    end if;
    
    if not ('qc.release' = any(v_perms)) then
      v_perms := array_append(v_perms, 'qc.release');
    end if;
    
    update public.admin_users 
    set permissions = v_perms
    where auth_user_id = v_user.auth_user_id;

  end loop;
end $$;
