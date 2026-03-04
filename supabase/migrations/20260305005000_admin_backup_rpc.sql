-- Migration: 20260305005000_admin_backup_rpc.sql
-- Description: Creates secure RPC functions for the dynamic visual backup system.

-- 1. Function to list all tables in the public schema
CREATE OR REPLACE FUNCTION admin_get_all_tables()
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_admin_permission('system.settings') THEN
     RAISE EXCEPTION 'Unauthorized: Requires system.settings permission';
  END IF;
  
  RETURN ARRAY(
     SELECT table_name::text 
     FROM information_schema.tables 
     WHERE table_schema = 'public' 
       AND table_type = 'BASE TABLE'
     ORDER BY table_name
  );
END;
$$;

-- 2. Function to fetch data from a table with pagination natively (bypassing RLS safely)
CREATE OR REPLACE FUNCTION admin_export_table_data(p_table text, p_offset int, p_limit int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  res jsonb;
  exec_query text;
BEGIN
  IF NOT public.has_admin_permission('system.settings') THEN
     RAISE EXCEPTION 'Unauthorized: Requires system.settings permission';
  END IF;
  
  -- Basic prevention against SQL injection in table name
  IF p_table !~ '^[a-zA-Z0-9_]+$' THEN
     RAISE EXCEPTION 'Invalid table name';
  END IF;
  
  -- Try to order by created_at if it exists, otherwise fall back to simple select
  BEGIN
    exec_query := format(
      'SELECT COALESCE(jsonb_agg(row_to_json(t)), ''[]''::jsonb) FROM (SELECT * FROM public.%I ORDER BY created_at ASC NULLS LAST LIMIT %s OFFSET %s) t',
      p_table, p_limit, p_offset
    );
    EXECUTE exec_query INTO res;
  EXCEPTION WHEN OTHERS THEN
    exec_query := format(
      'SELECT COALESCE(jsonb_agg(row_to_json(t)), ''[]''::jsonb) FROM (SELECT * FROM public.%I LIMIT %s OFFSET %s) t',
      p_table, p_limit, p_offset
    );
    EXECUTE exec_query INTO res;
  END;
  
  RETURN COALESCE(res, '[]'::jsonb);
END;
$$;

-- Grant execute permissions to the authenticated role
GRANT EXECUTE ON FUNCTION admin_get_all_tables() TO authenticated;
GRANT EXECUTE ON FUNCTION admin_export_table_data(text, int, int) TO authenticated;
