
-- List all admin_users to see if Yassen exists and compare IDs
SELECT 
    id,
    auth_user_id,
    username,
    email,
    role,
    is_active
FROM public.admin_users;
