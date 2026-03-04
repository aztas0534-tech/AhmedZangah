DO $$
DECLARE
  v_email text := 'aztas0534@gmail.com';
  v_user_id uuid;
  v_company_id uuid;
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_has_email_confirmed_at boolean;
  v_has_confirmed_at boolean;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_email LIMIT 1;
  IF v_user_id IS NULL THEN
    RAISE NOTICE 'Owner auth user not found for %', v_email;
    RETURN;
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'email_confirmed_at'
  ) INTO v_has_email_confirmed_at;
  SELECT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'confirmed_at'
  ) INTO v_has_confirmed_at;

  IF v_has_email_confirmed_at THEN
    UPDATE auth.users SET email_confirmed_at = now() WHERE id = v_user_id;
  ELSIF v_has_confirmed_at THEN
    UPDATE auth.users SET confirmed_at = now() WHERE id = v_user_id;
  END IF;

  SELECT id INTO v_company_id FROM public.companies LIMIT 1;
  SELECT id INTO v_branch_id FROM public.branches WHERE company_id = v_company_id LIMIT 1;
  SELECT id INTO v_warehouse_id FROM public.warehouses WHERE branch_id = v_branch_id LIMIT 1;

  DELETE FROM public.admin_users WHERE role = 'owner' AND auth_user_id <> v_user_id;

  IF EXISTS (SELECT 1 FROM public.admin_users WHERE auth_user_id = v_user_id) THEN
    UPDATE public.admin_users
    SET username = 'aztas0534',
        full_name = 'أحمد محمد زنقاح',
        email = v_email,
        role = 'owner',
        permissions = NULL,
        is_active = true,
        company_id = v_company_id,
        branch_id = v_branch_id,
        warehouse_id = v_warehouse_id
    WHERE auth_user_id = v_user_id;
  ELSE
    INSERT INTO public.admin_users (
      auth_user_id,
      username,
      full_name,
      email,
      role,
      permissions,
      is_active,
      company_id,
      branch_id,
      warehouse_id
    ) VALUES (
      v_user_id,
      'aztas0534',
      'أحمد محمد زنقاح',
      v_email,
      'owner',
      NULL,
      true,
      v_company_id,
      v_branch_id,
      v_warehouse_id
    );
  END IF;
END $$;
