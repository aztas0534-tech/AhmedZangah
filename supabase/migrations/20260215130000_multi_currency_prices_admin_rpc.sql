set app.allow_ledger_ddl = '1';

create or replace function public.upsert_item_currency_price_admin(
  p_item_id text,
  p_currency_code text,
  p_price_value numeric,
  p_effective_from date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_item text;
  v_cur text;
  v_from date;
begin
  if not (public.is_admin() or public.has_admin_permission('prices.manage')) then
    raise exception 'not allowed';
  end if;

  v_item := nullif(btrim(coalesce(p_item_id, '')), '');
  v_cur := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  v_from := coalesce(p_effective_from, current_date);

  if v_item is null then
    raise exception 'item required';
  end if;
  if v_cur is null then
    raise exception 'currency required';
  end if;
  if p_price_value is null or p_price_value < 0 then
    raise exception 'price must be >= 0';
  end if;

  update public.product_prices_multi_currency
  set is_active = false, updated_at = now()
  where item_id = v_item
    and upper(currency_code) = v_cur
    and is_active = true;

  insert into public.product_prices_multi_currency(
    item_id, currency_code, pricing_method, price_value, fx_source, is_active, effective_from
  )
  values (
    v_item, v_cur, 'MANUAL_OVERRIDE', p_price_value, 'NONE', true, v_from
  )
  returning id into v_id;

  begin
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
    values (
      'upsert',
      'prices',
      concat(v_item, ' ', v_cur, ' = ', p_price_value::text),
      auth.uid(),
      now(),
      jsonb_build_object('itemId', v_item, 'currency', v_cur, 'price', p_price_value, 'effective_from', v_from::text)
    );
  exception when others then
    null;
  end;

  return v_id;
end;
$$;

revoke all on function public.upsert_item_currency_price_admin(text, text, numeric, date) from public;
revoke execute on function public.upsert_item_currency_price_admin(text, text, numeric, date) from anon;
grant execute on function public.upsert_item_currency_price_admin(text, text, numeric, date) to authenticated;

notify pgrst, 'reload schema';
