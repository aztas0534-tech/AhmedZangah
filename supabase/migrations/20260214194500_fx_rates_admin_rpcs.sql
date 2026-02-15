create or replace function public.get_fx_rates_admin(
  p_currency text default null,
  p_rate_type text default null,
  p_limit integer default 500,
  p_offset integer default 0
)
returns table (
  id uuid,
  currency_code text,
  rate numeric,
  rate_date date,
  rate_type text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;

  return query
  select fr.id, fr.currency_code, fr.rate, fr.rate_date, fr.rate_type
  from public.fx_rates fr
  where (p_currency is null or upper(fr.currency_code) = upper(p_currency))
    and (p_rate_type is null or fr.rate_type = lower(p_rate_type))
  order by fr.rate_date desc, fr.currency_code asc
  limit greatest(coalesce(p_limit, 0), 0)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;
revoke all on function public.get_fx_rates_admin(text, text, integer, integer) from public;
revoke execute on function public.get_fx_rates_admin(text, text, integer, integer) from anon;
grant execute on function public.get_fx_rates_admin(text, text, integer, integer) to authenticated;

create or replace function public.upsert_fx_rate_admin(
  p_currency_code text,
  p_rate numeric,
  p_rate_date date,
  p_rate_type text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_code text;
  v_type text;
  v_date date;
begin
  if not (public.is_admin() or public.has_admin_permission('fx.manage')) then
    raise exception 'not allowed';
  end if;

  v_code := upper(nullif(btrim(coalesce(p_currency_code, '')), ''));
  v_type := lower(nullif(btrim(coalesce(p_rate_type, '')), ''));
  v_date := coalesce(p_rate_date, current_date);

  if v_code is null then
    raise exception 'currency required';
  end if;
  if v_type is null then
    v_type := 'operational';
  end if;
  if p_rate is null or p_rate <= 0 then
    raise exception 'rate must be > 0';
  end if;

  insert into public.fx_rates(currency_code, rate, rate_date, rate_type)
  values (v_code, p_rate, v_date, v_type)
  on conflict (currency_code, rate_date, rate_type)
  do update set rate = excluded.rate
  returning id into v_id;

  begin
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
    values (
      'upsert',
      'fx_rates',
      concat(v_code, ' ', v_type, ' ', v_date::text, ' = ', p_rate::text),
      auth.uid(),
      now(),
      jsonb_build_object('currency', v_code, 'rate', p_rate, 'rate_date', v_date, 'rate_type', v_type)
    );
  exception when others then
    null;
  end;

  return v_id;
end;
$$;
revoke all on function public.upsert_fx_rate_admin(text, numeric, date, text) from public;
revoke execute on function public.upsert_fx_rate_admin(text, numeric, date, text) from anon;
grant execute on function public.upsert_fx_rate_admin(text, numeric, date, text) to authenticated;

create or replace function public.delete_fx_rate_admin(
  p_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
begin
  if not (public.is_admin() or public.has_admin_permission('fx.manage')) then
    raise exception 'not allowed';
  end if;

  if p_id is null then
    raise exception 'id required';
  end if;

  select currency_code, rate, rate_date, rate_type
  into v_row
  from public.fx_rates
  where id = p_id;

  delete from public.fx_rates where id = p_id;

  begin
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
    values (
      'delete',
      'fx_rates',
      concat(coalesce(v_row.currency_code, ''), ' ', coalesce(v_row.rate_type, ''), ' ', coalesce(v_row.rate_date::text, '')),
      auth.uid(),
      now(),
      jsonb_build_object('id', p_id, 'currency', v_row.currency_code, 'rate', v_row.rate, 'rate_date', v_row.rate_date, 'rate_type', v_row.rate_type)
    );
  exception when others then
    null;
  end;
end;
$$;
revoke all on function public.delete_fx_rate_admin(uuid) from public;
revoke execute on function public.delete_fx_rate_admin(uuid) from anon;
grant execute on function public.delete_fx_rate_admin(uuid) to authenticated;

notify pgrst, 'reload schema';
