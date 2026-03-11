-- Migration: 20260305011000_admin_wipe_restore.sql
-- Description: Creates an RPC function to truncate user data tables for a full restore.

CREATE OR REPLACE FUNCTION admin_wipe_all_tables_for_restore()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 1. Security check
  IF NOT public.has_admin_permission('system.settings') THEN
     RAISE EXCEPTION 'Unauthorized: Requires system.settings permission';
  END IF;

  -- 2. Truncate tables in an order that respects foreign key constraints
  -- We use CASCADE to handle complex relationships but try to order them logically.
  
  -- Most dependent tables first:
  TRUNCATE TABLE public.journal_entry_lines CASCADE;
  TRUNCATE TABLE public.journal_entries CASCADE;
  
  TRUNCATE TABLE public.invoice_items CASCADE;
  TRUNCATE TABLE public.invoices CASCADE;
  TRUNCATE TABLE public.pos_sessions CASCADE;
  TRUNCATE TABLE public.pos_terminals CASCADE;

  TRUNCATE TABLE public.purchase_items CASCADE;
  TRUNCATE TABLE public.purchases CASCADE;
  
  TRUNCATE TABLE public.inventory_movements CASCADE;
  TRUNCATE TABLE public.item_warehouses CASCADE;
  
  TRUNCATE TABLE public.vouchers CASCADE;
  
  TRUNCATE TABLE public.cash_shifts CASCADE;
  
  -- Less dependent / Core entities
  TRUNCATE TABLE public.items CASCADE;
  TRUNCATE TABLE public.categories CASCADE;
  
  TRUNCATE TABLE public.financial_parties CASCADE;
  TRUNCATE TABLE public.chart_of_accounts CASCADE;
  
  TRUNCATE TABLE public.employees CASCADE;
  TRUNCATE TABLE public.roles CASCADE;
  
  TRUNCATE TABLE public.warehouses CASCADE;
  TRUNCATE TABLE public.branches CASCADE;
  TRUNCATE TABLE public.organization_settings CASCADE;

  -- End of wipe. The restore process will immediately repopulate these.
END;
$$;

GRANT EXECUTE ON FUNCTION admin_wipe_all_tables_for_restore() TO authenticated;
