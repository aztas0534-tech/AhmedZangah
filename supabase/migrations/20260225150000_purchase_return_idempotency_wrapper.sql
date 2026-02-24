set app.allow_ledger_ddl = '1';

do $$
begin
  if to_regclass('public.purchase_returns') is not null then
    begin
      create unique index if not exists uq_purchase_returns_order_idempotency
        on public.purchase_returns(purchase_order_id, idempotency_key)
        where idempotency_key is not null and btrim(idempotency_key) <> '';
    exception when others then
      null;
    end;
  end if;
end $$;

create or replace function public.create_purchase_return_v2(
  p_order_id uuid,
  p_items jsonb,
  p_reason text default null,
  p_occurred_at timestamptz default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_existing uuid;
  v_created uuid;
begin
  if v_key is not null then
    select pr.id
    into v_existing
    from public.purchase_returns pr
    where pr.purchase_order_id = p_order_id
      and pr.idempotency_key = v_key
    limit 1;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  if v_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('purchase_return:' || p_order_id::text || ':' || v_key, 0));
    select pr.id
    into v_existing
    from public.purchase_returns pr
    where pr.purchase_order_id = p_order_id
      and pr.idempotency_key = v_key
    limit 1;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  v_created := public.create_purchase_return(p_order_id, p_items, p_reason, p_occurred_at);

  if v_key is not null then
    begin
      update public.purchase_returns
      set idempotency_key = v_key
      where id = v_created
        and (idempotency_key is null or btrim(idempotency_key) = '');
    exception when unique_violation then
      select pr.id
      into v_existing
      from public.purchase_returns pr
      where pr.purchase_order_id = p_order_id
        and pr.idempotency_key = v_key
      limit 1;
      if v_existing is not null then
        return v_existing;
      end if;
      raise;
    end;
  end if;

  return v_created;
end;
$$;

revoke all on function public.create_purchase_return_v2(uuid, jsonb, text, timestamptz, text) from public;
revoke execute on function public.create_purchase_return_v2(uuid, jsonb, text, timestamptz, text) from anon;
grant execute on function public.create_purchase_return_v2(uuid, jsonb, text, timestamptz, text) to authenticated;

notify pgrst, 'reload schema';

