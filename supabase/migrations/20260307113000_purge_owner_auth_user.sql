DO $$
DECLARE
  v_email text := 'aztas0534@gmail.com';
  v_user_id uuid;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_email LIMIT 1;
  IF v_user_id IS NOT NULL THEN
    DELETE FROM auth.identities WHERE user_id = v_user_id;
    DELETE FROM auth.users WHERE id = v_user_id;
  END IF;

  DELETE FROM public.admin_users WHERE role = 'owner' AND (email = v_email OR auth_user_id = v_user_id);
END $$;
