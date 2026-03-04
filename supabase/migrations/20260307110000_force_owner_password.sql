DO $$
DECLARE
  v_email text := 'aztas0534@gmail.com';
  v_password text := 'Aztas718642';
  v_owner_admin_id uuid;
  v_user_id uuid;
  v_company_id uuid;
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_has_email_confirmed_at boolean;
  v_has_confirmed_at boolean;
  v_has_set_password boolean;
BEGIN
  SELECT auth_user_id
    INTO v_owner_admin_id
  FROM public.admin_users
  WHERE role = 'owner'
  ORDER BY created_at NULLS LAST, auth_user_id
  LIMIT 1;

  SELECT id
    INTO v_user_id
  FROM auth.users
  WHERE email = v_email
  LIMIT 1;

  IF v_user_id IS NULL AND v_owner_admin_id IS NOT NULL THEN
    SELECT id INTO v_user_id FROM auth.users WHERE id = v_owner_admin_id;
  END IF;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();
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
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      extensions.crypt(v_password, extensions.gen_salt('bf')),
      '{"provider": "email", "providers": ["email"]}',
      '{"full_name": "أحمد محمد زنقاح"}',
      now(),
      now()
    );
  END IF;

  SELECT to_regprocedure('auth.set_user_password(uuid,text)') IS NOT NULL
    INTO v_has_set_password;

  IF v_has_set_password THEN
    PERFORM auth.set_user_password(v_user_id, v_password);
  ELSE
    UPDATE auth.users
    SET encrypted_password = extensions.crypt(v_password, extensions.gen_salt('bf'))
    WHERE id = v_user_id;
  END IF;

  UPDATE auth.users
  SET email = v_email,
      raw_app_meta_data = '{"provider": "email", "providers": ["email"]}',
      raw_user_meta_data = '{"full_name": "أحمد محمد زنقاح"}',
      updated_at = now(),
      banned_until = NULL,
      deleted_at = NULL
  WHERE id = v_user_id;

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

  IF to_regclass('auth.identities') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM auth.identities WHERE user_id = v_user_id AND provider = 'email'
    ) THEN
      INSERT INTO auth.identities (
        id,
        user_id,
        identity_data,
        provider,
        provider_id,
        last_sign_in_at,
        created_at,
        updated_at
      ) VALUES (
        gen_random_uuid(),
        v_user_id,
        jsonb_build_object('sub', v_user_id::text, 'email', v_email),
        'email',
        v_email,
        now(),
        now(),
        now()
      );
    ELSE
      UPDATE auth.identities
      SET provider_id = v_email,
          identity_data = jsonb_build_object('sub', v_user_id::text, 'email', v_email),
          updated_at = now()
      WHERE user_id = v_user_id AND provider = 'email';
    END IF;
  END IF;

  SELECT id INTO v_company_id FROM public.companies LIMIT 1;
  SELECT id INTO v_branch_id FROM public.branches WHERE company_id = v_company_id LIMIT 1;
  SELECT id INTO v_warehouse_id FROM public.warehouses WHERE branch_id = v_branch_id LIMIT 1;

  IF v_owner_admin_id IS NULL THEN
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
  ELSE
    UPDATE public.admin_users
    SET auth_user_id = v_user_id,
        username = 'aztas0534',
        full_name = 'أحمد محمد زنقاح',
        email = v_email,
        role = 'owner',
        permissions = NULL,
        is_active = true,
        company_id = v_company_id,
        branch_id = v_branch_id,
        warehouse_id = v_warehouse_id
    WHERE auth_user_id = v_owner_admin_id;
  END IF;
END $$;
