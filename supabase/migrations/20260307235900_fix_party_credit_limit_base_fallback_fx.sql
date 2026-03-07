create or replace function public.check_party_credit_limit(
  p_party_id uuid,
  p_order_amount_base numeric,
  p_currency_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit numeric := 0;
  v_hold boolean := false;
  v_is_active boolean := true;
  v_balance numeric := 0;
  v_base text;
  v_currency text;
  v_pcl record;
  v_fx numeric := 1;
  v_amount_in_currency numeric := 0;
  v_amount_base numeric := 0;
begin
  if p_party_id is null then
    return true;
  end if;

  v_base := public.get_base_currency();
  v_currency := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  if v_currency is null or v_currency = '' then
    v_currency := v_base;
  end if;
  v_amount_in_currency := greatest(coalesce(p_order_amount_base, 0), 0);

  select coalesce(p.is_active, true) into v_is_active
  from public.financial_parties p
  where p.id = p_party_id;

  if not found then
    return false;
  end if;

  if v_is_active = false then
    return false;
  end if;

  select pcl.* into v_pcl
  from public.party_credit_limits pcl
  where pcl.party_id = p_party_id and pcl.currency_code = v_currency;

  if found then
    if v_pcl.credit_hold then
      return v_amount_in_currency <= 0;
    end if;
    v_limit := coalesce(v_pcl.credit_limit, 0);
    if v_limit <= 0 then
      return v_amount_in_currency <= 0;
    end if;
    select coalesce(bal.ar_balance, 0) into v_balance
    from public.compute_party_ar_balance_by_currency(p_party_id, v_currency) bal
    limit 1;
    return (greatest(v_balance, 0) + v_amount_in_currency) <= v_limit;
  end if;

  if upper(v_currency) = upper(v_base) then
    v_amount_base := v_amount_in_currency;
  else
    v_fx := public.get_fx_rate(v_currency, current_date, 'operational');
    if v_fx is null or v_fx <= 0 then
      return false;
    end if;
    v_amount_base := v_amount_in_currency * v_fx;
  end if;

  select coalesce(p.credit_limit_base, 0), coalesce(p.credit_hold, false)
  into v_limit, v_hold
  from public.financial_parties p
  where p.id = p_party_id;

  if v_hold then
    return v_amount_base <= 0;
  end if;

  if v_limit <= 0 then
    return v_amount_base <= 0;
  end if;

  v_balance := public.compute_party_ar_balance(p_party_id);
  return (greatest(v_balance, 0) + greatest(v_amount_base, 0)) <= v_limit;
end;
$$;
