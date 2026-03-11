-- Fix PGRST203: PostgREST cannot disambiguate between 5-param and 6-param
-- get_fefo_pricing overloads when called with exactly 5 named parameters.
-- The 5-param version is redundant since the 6-param version has
-- p_batch_id uuid DEFAULT NULL.
-- Drop the 5-param TEXT overload to resolve the ambiguity.

DROP FUNCTION IF EXISTS public.get_fefo_pricing(
  p_item_id text,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_customer_id uuid,
  p_currency_code text
);
