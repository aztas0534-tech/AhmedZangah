-- Migration: Create Local Owner User
-- Description: Inserts a default owner user for local development if it doesn't exist.

DO $$
DECLARE
  v_user_id uuid;
  v_encrypted_pw text;
  v_company_id uuid;
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_has_email_confirmed_at boolean;
  v_has_confirmed_at boolean;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = 'owner@azta.com';

  IF v_user_id IS NULL THEN
    v_encrypted_pw := crypt('Owner@123', gen_salt('bf'));

    -- Insert with a minimal, cross-version column set
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
      'owner@azta.com',
      v_encrypted_pw,
      '{"provider": "email", "providers": ["email"]}',
      '{"full_name": "Owner User"}',
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

    v_company_id := null;
    v_branch_id := null;
    v_warehouse_id := null;

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
      'owner',
      'Owner User',
      'owner@azta.com',
      'owner',
      NULL,
      true,
      v_company_id,
      v_branch_id,
      v_warehouse_id
    );

    RAISE NOTICE 'Created owner user: owner@azta.com / Owner@123';
  ELSE
    RAISE NOTICE 'Owner user already exists: owner@azta.com';
  END IF;
END $$;
