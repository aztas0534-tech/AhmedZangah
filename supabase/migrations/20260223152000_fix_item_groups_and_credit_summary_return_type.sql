set app.allow_ledger_ddl = '1';

do $$
begin
  if to_regclass('public.item_groups') is null then
    create table public.item_groups (
      id uuid primary key default gen_random_uuid(),
      category_key text not null,
      key text not null,
      is_active boolean not null default true,
      data jsonb not null default '{}'::jsonb,
      created_at timestamptz not null default now(),
      updated_at timestamptz not null default now(),
      unique (category_key, key)
    );

    create index if not exists idx_item_groups_key on public.item_groups(key);

    alter table public.item_groups enable row level security;

    drop trigger if exists trg_item_groups_updated_at on public.item_groups;
    create trigger trg_item_groups_updated_at
    before update on public.item_groups
    for each row execute function public.set_updated_at();

    drop policy if exists item_groups_select_all on public.item_groups;
    create policy item_groups_select_all
    on public.item_groups
    for select
    using (true);

    drop policy if exists item_groups_write_admin on public.item_groups;
    create policy item_groups_write_admin
    on public.item_groups
    for all
    using (public.is_admin())
    with check (public.is_admin());
  end if;
end $$;

do $$
begin
  if to_regprocedure('public.get_party_credit_summary(uuid)') is not null then
    begin
      drop function public.get_party_credit_summary(uuid);
    exception when others then
      null;
    end;
  end if;
end $$;

create or replace function public.get_party_credit_summary(p_party_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_party record;
  v_balance numeric := 0;
  v_available numeric := 0;
begin
  if not public.has_admin_permission('accounting.view') then
    raise exception 'not allowed';
  end if;

  select p.*
  into v_party
  from public.financial_parties p
  where p.id = p_party_id;

  if not found then
    return jsonb_build_object('exists', false);
  end if;

  v_balance := public.compute_party_ar_balance(p_party_id);
  v_available := greatest(coalesce(v_party.credit_limit_base, 0) - greatest(v_balance, 0), 0);

  return jsonb_build_object(
    'exists', true,
    'party_mode', true,
    'party_id', p_party_id,
    'party_type', v_party.party_type,
    'is_active', v_party.is_active,
    'credit_hold', coalesce(v_party.credit_hold, false),
    'credit_limit', coalesce(v_party.credit_limit_base, 0),
    'current_balance', v_balance,
    'available_credit', v_available,
    'net_days_default', coalesce(v_party.credit_net_days, 30)
  );
end;
$$;

revoke all on function public.get_party_credit_summary(uuid) from public;
revoke execute on function public.get_party_credit_summary(uuid) from anon;
grant execute on function public.get_party_credit_summary(uuid) to authenticated;

select pg_sleep(0.2);
notify pgrst, 'reload schema';

