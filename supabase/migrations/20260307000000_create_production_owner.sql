-- Migration: Create Production Owner User
-- Description: Inserts the owner account with full permissions for production.

DO $$
DECLARE
  v_user_id uuid;
  v_encrypted_pw text;
  v_company_id uuid;
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_has_email_confirmed_at boolean;
  v_has_confirmed_at boolean;
  v_owner_exists boolean;
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM public.admin_users WHERE role = 'owner'
  ) INTO v_owner_exists;

  IF v_owner_exists THEN
    RAISE NOTICE 'Owner already exists, skipping create_production_owner';
    RETURN;
  END IF;

  SELECT id INTO v_user_id FROM auth.users WHERE email = 'aztas0534@gmail.com';

  IF v_user_id IS NULL THEN
    v_encrypted_pw := extensions.crypt('Aztas718642', extensions.gen_salt('bf'));

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
    ) RETURNING id INTO v_user_id;

    -- Mark email as confirmed depending on available column
    SELECT EXISTS(
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='auth' AND table_name='users' AND column_name='email_confirmed_at'
    ) INTO v_has_email_confirmed_at;
    SELECT EXISTS(
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='auth' AND table_name='users' AND column_name='confirmed_at'
    ) INTO v_has_confirmed_at;

    IF v_has_email_confirmed_at THEN
      UPDATE auth.users SET email_confirmed_at = now() WHERE id = v_user_id;
    ELSIF v_has_confirmed_at THEN
      UPDATE auth.users SET confirmed_at = now() WHERE id = v_user_id;
    END IF;

    -- Resolve default company, branch, warehouse
    SELECT id INTO v_company_id FROM public.companies LIMIT 1;
    SELECT id INTO v_branch_id FROM public.branches WHERE company_id = v_company_id LIMIT 1;
    SELECT id INTO v_warehouse_id FROM public.warehouses WHERE branch_id = v_branch_id LIMIT 1;

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
      'aztas0534@gmail.com',
      'owner',
      NULL,
      true,
      v_company_id,
      v_branch_id,
      v_warehouse_id
    );

    RAISE NOTICE 'Created owner user: aztas0534@gmail.com';
  ELSE
    RAISE NOTICE 'Owner user already exists: aztas0534@gmail.com';
  END IF;
END $$;
