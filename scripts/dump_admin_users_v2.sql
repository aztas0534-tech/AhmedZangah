
-- Check columns of admin_users
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'admin_users';

-- List admin_users (using * to avoid column error)
SELECT * FROM public.admin_users;
