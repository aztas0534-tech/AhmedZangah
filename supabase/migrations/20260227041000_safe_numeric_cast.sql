create or replace function public.safe_cast_numeric(p_val text)
returns numeric
language plpgsql immutable
as $$
begin
  if p_val is null or btrim(p_val) = '' then
    return null;
  end if;
  return p_val::numeric;
exception when others then
  return null;
end;
$$;
