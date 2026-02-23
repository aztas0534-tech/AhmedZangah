create or replace function public.app_schema_healthcheck()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_missing text[] := array[]::text[];
  v_applied text := '';
  v_oid oid;
  v_res text := '';
begin
  if auth.role() <> 'service_role' then
    if not public.is_admin() then
      raise exception 'not allowed';
    end if;
  end if;

  begin
    select coalesce(max(version), '') into v_applied
    from supabase_migrations.schema_migrations;
  exception when others then
    v_applied := '';
  end;

  if to_regclass('public.orders') is null then v_missing := array_append(v_missing, 'table:orders'); end if;
  if to_regclass('public.payments') is null then v_missing := array_append(v_missing, 'table:payments'); end if;
  if to_regclass('public.item_categories') is null then v_missing := array_append(v_missing, 'table:item_categories'); end if;
  if to_regclass('public.item_groups') is null then v_missing := array_append(v_missing, 'table:item_groups'); end if;
  if to_regclass('public.unit_types') is null then v_missing := array_append(v_missing, 'table:unit_types'); end if;
  if to_regclass('public.uom') is null then v_missing := array_append(v_missing, 'table:uom'); end if;
  if to_regclass('public.item_uom') is null then v_missing := array_append(v_missing, 'table:item_uom'); end if;
  if to_regclass('public.item_uom_units') is null then v_missing := array_append(v_missing, 'table:item_uom_units'); end if;
  if to_regclass('public.financial_parties') is null then v_missing := array_append(v_missing, 'table:financial_parties'); end if;
  if to_regclass('public.party_credit_overrides') is null then v_missing := array_append(v_missing, 'table:party_credit_overrides'); end if;

  v_oid := to_regprocedure('public.confirm_order_delivery(uuid,jsonb,jsonb,uuid)');
  if v_oid is null then
    v_missing := array_append(v_missing, 'fn:confirm_order_delivery(uuid,jsonb,jsonb,uuid)');
  else
    select pg_get_function_result(v_oid) into v_res;
    if lower(coalesce(v_res, '')) not like '%jsonb%' then
      v_missing := array_append(v_missing, 'fn:confirm_order_delivery(uuid,jsonb,jsonb,uuid):return_jsonb');
    end if;
  end if;

  v_oid := to_regprocedure('public.confirm_order_delivery(jsonb)');
  if v_oid is null then
    v_missing := array_append(v_missing, 'fn:confirm_order_delivery(jsonb)');
  else
    select pg_get_function_result(v_oid) into v_res;
    if lower(coalesce(v_res, '')) not like '%jsonb%' then
      v_missing := array_append(v_missing, 'fn:confirm_order_delivery(jsonb):return_jsonb');
    end if;
  end if;

  v_oid := to_regprocedure('public.confirm_order_delivery_with_credit(uuid,jsonb,jsonb,uuid)');
  if v_oid is null then
    v_missing := array_append(v_missing, 'fn:confirm_order_delivery_with_credit(uuid,jsonb,jsonb,uuid)');
  else
    select pg_get_function_result(v_oid) into v_res;
    if lower(coalesce(v_res, '')) not like '%jsonb%' then
      v_missing := array_append(v_missing, 'fn:confirm_order_delivery_with_credit(uuid,jsonb,jsonb,uuid):return_jsonb');
    end if;
  end if;

  v_oid := to_regprocedure('public.confirm_order_delivery_with_credit(jsonb)');
  if v_oid is null then
    v_missing := array_append(v_missing, 'fn:confirm_order_delivery_with_credit(jsonb)');
  else
    select pg_get_function_result(v_oid) into v_res;
    if lower(coalesce(v_res, '')) not like '%jsonb%' then
      v_missing := array_append(v_missing, 'fn:confirm_order_delivery_with_credit(jsonb):return_jsonb');
    end if;
  end if;

  v_oid := to_regprocedure('public.issue_invoice_on_delivery()');
  if v_oid is null then
    v_missing := array_append(v_missing, 'fn:issue_invoice_on_delivery()');
  else
    select pg_get_function_result(v_oid) into v_res;
    if lower(coalesce(v_res, '')) not like '%trigger%' then
      v_missing := array_append(v_missing, 'fn:issue_invoice_on_delivery():return_trigger');
    end if;
  end if;

  v_oid := to_regprocedure('public.get_party_credit_summary(uuid)');
  if v_oid is null then
    v_missing := array_append(v_missing, 'fn:get_party_credit_summary(uuid)');
  else
    select pg_get_function_result(v_oid) into v_res;
    if lower(coalesce(v_res, '')) not like '%jsonb%' then
      v_missing := array_append(v_missing, 'fn:get_party_credit_summary(uuid):return_jsonb');
    end if;
  end if;

  return jsonb_build_object(
    'ok', coalesce(array_length(v_missing, 1), 0) = 0,
    'appliedVersion', coalesce(v_applied, ''),
    'missing', to_jsonb(v_missing)
  );
end;
$$;

revoke all on function public.app_schema_healthcheck() from public;
revoke execute on function public.app_schema_healthcheck() from anon;
grant execute on function public.app_schema_healthcheck() to authenticated;

select pg_sleep(0.2);
notify pgrst, 'reload schema';
