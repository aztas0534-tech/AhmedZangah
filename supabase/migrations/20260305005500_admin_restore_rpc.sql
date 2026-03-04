-- Migration: 20260305005500_admin_restore_rpc.sql
-- Description: Creates an RPC function to safely restore tables data from JSON, ignoring existing IDs to prevent duplicates.

CREATE OR REPLACE FUNCTION admin_import_table_data(p_table text, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count int := 0;
  v_record jsonb;
  v_columns text;
  v_values text;
  v_sql text;
  v_key text;
  v_val text;
  v_inserted int := 0;
BEGIN
  -- 1. Security check
  IF NOT public.has_admin_permission('system.settings') THEN
     RAISE EXCEPTION 'Unauthorized: Requires system.settings permission';
  END IF;

  -- 2. Validate table name to prevent SQL injection
  IF p_table !~ '^[a-zA-Z0-9_]+$' THEN
     RAISE EXCEPTION 'Invalid table name';
  END IF;

  -- If it's not an array, return 0
  IF jsonb_typeof(p_data) != 'array' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Data must be an array');
  END IF;

  v_count := jsonb_array_length(p_data);
  IF v_count = 0 THEN
    RETURN jsonb_build_object('status', 'success', 'inserted_count', 0);
  END IF;

  -- 3. The challenge with a generic import is knowing the columns.
  -- A safer, PostgreSQL 10+ way to insert arbitrary JSON array into a table:
  -- We use jsonb_populate_recordset on a null record of the target table.
  -- We use ON CONFLICT DO NOTHING to ensure we don't crash if the record exists.
  
  -- Since ON CONFLICT requires knowing the unique constraint (usually id),
  -- we'll assume the primary key is 'id' for most tables.
  
  BEGIN
    -- Construct a dynamic SQL statement.
    -- jsonb_populate_recordset(null::public.table_name, p_data) expands the JSON into table rows.
    v_sql := format(
      'INSERT INTO public.%I
       SELECT * FROM jsonb_populate_recordset(null::public.%I, $1)
       ON CONFLICT (id) DO NOTHING',
      p_table, p_table
    );
    
    EXECUTE v_sql USING p_data;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    
  EXCEPTION WHEN OTHERS THEN
    -- If it fails (e.g. table doesn't have an 'id' primary key or missing constraint), 
    -- we do a fallback basic insert without ON CONFLICT (will fail if dupes exist, which is safer than blind overwrite)
    BEGIN
       v_sql := format(
         'INSERT INTO public.%I
          SELECT * FROM jsonb_populate_recordset(null::public.%I, $1)',
         p_table, p_table
       );
       EXECUTE v_sql USING p_data;
       GET DIAGNOSTICS v_inserted = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
       RETURN jsonb_build_object('status', 'error', 'message', SQLERRM, 'table', p_table);
    END;
  END;

  RETURN jsonb_build_object('status', 'success', 'inserted_count', v_inserted, 'table', p_table);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_import_table_data(text, jsonb) TO authenticated;
