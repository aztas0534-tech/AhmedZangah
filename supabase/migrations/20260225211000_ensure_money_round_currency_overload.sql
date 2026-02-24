create or replace function public._money_round(p_value numeric, p_scale int default 2)
returns numeric
language plpgsql
as $$
begin
  return round(coalesce(p_value, 0), coalesce(p_scale, 2));
end;
$$;

create or replace function public._money_round(p_value numeric, p_currency text)
returns numeric
language plpgsql
stable
as $$
declare
  v_scale int;
begin
  v_scale := null;
  begin
    select c.decimal_places
    into v_scale
    from public.currencies c
    where upper(c.code) = upper(p_currency)
    limit 1;
  exception when undefined_table then
    v_scale := null;
  end;

  return public._money_round(p_value, coalesce(v_scale, 2));
end;
$$;

revoke all on function public._money_round(numeric, int) from public;
revoke all on function public._money_round(numeric, text) from public;
grant execute on function public._money_round(numeric, int) to authenticated;
grant execute on function public._money_round(numeric, text) to authenticated;

notify pgrst, 'reload schema';

