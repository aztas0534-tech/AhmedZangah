do $$
begin
  if to_regclass('public.customers') is null then
    return;
  end if;

  create schema if not exists extensions;

  begin
    create extension if not exists pgcrypto with schema extensions;
  exception when insufficient_privilege then
    null;
  end;
end $$;

create or replace function public.encrypt_text(p_text text)
returns bytea
language plpgsql
security definer
set search_path = extensions, public
as $$
declare
  v_key text;
begin
  select key_value
  into v_key
  from private.keys
  where key_name = 'app.encryption_key';

  if v_key is null or v_key = '' then
    raise exception 'Encryption key not configured';
  end if;

  if p_text is null or p_text = '' then
    return null;
  end if;

  return pgp_sym_encrypt(p_text, v_key);
end;
$$;

create or replace function public.decrypt_text(p_encrypted bytea)
returns text
language plpgsql
security definer
set search_path = extensions, public
as $$
declare
  v_key text;
begin
  select key_value
  into v_key
  from private.keys
  where key_name = 'app.encryption_key';

  if v_key is null or v_key = '' then
    raise exception 'Encryption key not configured';
  end if;

  if p_encrypted is null then
    return null;
  end if;

  begin
    return pgp_sym_decrypt(p_encrypted, v_key);
  exception when others then
    return null;
  end;
end;
$$;

notify pgrst, 'reload schema';

