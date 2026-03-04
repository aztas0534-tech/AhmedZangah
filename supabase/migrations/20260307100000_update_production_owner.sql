DO $$
DECLARE
  v_owner_auth_id uuid;
  v_target_auth_id uuid;
  v_company_id uuid;
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_encrypted_pw text;
  v_has_email_confirmed_at boolean;
  v_has_confirmed_at boolean;
BEGIN
  SELECT auth_user_id
    INTO v_owner_auth_id
  FROM public.admin_users
  WHERE role = 'owner'
  ORDER BY created_at NULLS LAST, auth_user_id
  LIMIT 1;

  SELECT id
    INTO v_target_auth_id
  FROM auth.users
  WHERE email = 'aztas0534@gmail.com'
  LIMIT 1;

  v_encrypted_pw := extensions.crypt('Aztas718642', extensions.gen_salt('bf'));

  IF v_target_auth_id IS NULL THEN
    IF v_owner_auth_id IS NULL THEN
      INSERT INTO auth.users (
        instance_id,
        id,
        aud,
        role,
        email,
        encrypted_password,
        raw_app_meta_data,
        raw_user_meta_data,
        created_at,
        updated_at
      ) VALUES (
        '00000000-0000-0000-0000-000000000000',
        gen_random_uuid(),
        'authenticated',
        'authenticated',
        'aztas0534@gmail.com',
        v_encrypted_pw,
        '{"provider": "email", "providers": ["email"]}',
        '{"full_name": "أحمد محمد زنقاح"}',
        now(),
        now()
      ) RETURNING id INTO v_target_auth_id;
    ELSE
      UPDATE auth.users
      SET email = 'aztas0534@gmail.com',
          encrypted_password = v_encrypted_pw,
          raw_app_meta_data = '{"provider": "email", "providers": ["email"]}',
          raw_user_meta_data = '{"full_name": "أحمد محمد زنقاح"}',
          updated_at = now()
      WHERE id = v_owner_auth_id;
      v_target_auth_id := v_owner_auth_id;
    END IF;
  ELSE
    UPDATE auth.users
    SET email = 'aztas0534@gmail.com',
        encrypted_password = v_encrypted_pw,
        raw_app_meta_data = '{"provider": "email", "providers": ["email"]}',
        raw_user_meta_data = '{"full_name": "أحمد محمد زنقاح"}',
        updated_at = now()
    WHERE id = v_target_auth_id;
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
    UPDATE auth.users SET email_confirmed_at = now() WHERE id = v_target_auth_id;
  ELSIF v_has_confirmed_at THEN
    UPDATE auth.users SET confirmed_at = now() WHERE id = v_target_auth_id;
  END IF;

  SELECT id INTO v_company_id FROM public.companies LIMIT 1;
  SELECT id INTO v_branch_id FROM public.branches WHERE company_id = v_company_id LIMIT 1;
  SELECT id INTO v_warehouse_id FROM public.warehouses WHERE branch_id = v_branch_id LIMIT 1;

  IF v_owner_auth_id IS NULL THEN
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
      v_target_auth_id,
      'aztas0534',
      'أحمد محمد زنقاح',
      'aztas0534@gmail.com',
      'owner',
      NULL,
      true,
      v_company_id,
      v_branch_id,
      v_warehouse_id
    );
  ELSE
    UPDATE public.admin_users
    SET auth_user_id = v_target_auth_id,
        username = 'aztas0534',
        full_name = 'أحمد محمد زنقاح',
        email = 'aztas0534@gmail.com',
        role = 'owner',
        permissions = NULL,
        is_active = true,
        company_id = v_company_id,
        branch_id = v_branch_id,
        warehouse_id = v_warehouse_id
    WHERE auth_user_id = v_owner_auth_id;
  END IF;
END $$;
