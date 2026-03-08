set app.allow_ledger_ddl = '1';

do $$
declare
  v_has_banks boolean := to_regclass('public.banks') is not null;
  v_has_recipients boolean := to_regclass('public.transfer_recipients') is not null;
begin
  create temporary table tmp_destination_account_map (
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  insert into tmp_destination_account_map(old_id, new_id)
  with base as (
    select
      a.id,
      a.code,
      a.name,
      case
        when upper(coalesce(a.code, '')) ~ '(^|[^0-9])1020([^0-9]|$)' then '1020'
        when upper(coalesce(a.code, '')) ~ '(^|[^0-9])1030([^0-9]|$)' then '1030'
        else null
      end as parent_code,
      case
        when upper(coalesce(a.code, '')) ~ '(^|[^A-Z])(YER)([^A-Z]|$)' then 'YER'
        when upper(coalesce(a.code, '')) ~ '(^|[^A-Z])(SAR)([^A-Z]|$)' then 'SAR'
        when upper(coalesce(a.code, '')) ~ '(^|[^A-Z])(USD)([^A-Z]|$)' then 'USD'
        when coalesce(a.name, '') ~ 'ريال يمني|يمني' then 'YER'
        when coalesce(a.name, '') ~ 'ريال سعودي|سعودي' then 'SAR'
        when coalesce(a.name, '') ~ 'دولار' then 'USD'
        else null
      end as currency_code,
      lower(regexp_replace(coalesce(a.name, ''), '\s+', ' ', 'g')) as normalized_name,
      case
        when upper(coalesce(a.code, '')) ~ '^(1020|1030)-[0-9]{3}-(YER|SAR|USD)$' then 40
        when upper(coalesce(a.code, '')) ~ '^(1020|1030)-[0-9]{3}$' then 30
        when upper(coalesce(a.code, '')) ~ '^(YER|SAR|USD)-(1020|1030)-[0-9]{3}$' then 20
        when upper(coalesce(a.code, '')) ~ '^(1020|1030)\.[0-9]{2,3}$' then 10
        else 0
      end as fmt_rank
    from public.chart_of_accounts a
    where coalesce(a.is_active, true) = true
  ),
  ranked as (
    select
      b.*,
      first_value(b.id) over (
        partition by b.parent_code, b.currency_code, b.normalized_name
        order by b.fmt_rank desc, b.code asc, b.id asc
      ) as keep_id,
      row_number() over (
        partition by b.parent_code, b.currency_code, b.normalized_name
        order by b.fmt_rank desc, b.code asc, b.id asc
      ) as rn
    from base b
    where b.parent_code in ('1020', '1030')
      and b.currency_code in ('YER', 'SAR', 'USD')
      and nullif(b.normalized_name, '') is not null
  )
  select r.id, r.keep_id
  from ranked r
  where r.rn > 1
    and r.id <> r.keep_id;

  if v_has_banks then
    update public.banks b
    set data = jsonb_set(
      coalesce(b.data, '{}'::jsonb),
      '{destinationAccountId}',
      to_jsonb(m.new_id::text),
      true
    )
    from tmp_destination_account_map m
    where coalesce(b.data->>'destinationAccountId', '') = m.old_id::text
      and m.old_id <> m.new_id;
  end if;

  if v_has_recipients then
    update public.transfer_recipients r
    set data = jsonb_set(
      coalesce(r.data, '{}'::jsonb),
      '{destinationAccountId}',
      to_jsonb(m.new_id::text),
      true
    )
    from tmp_destination_account_map m
    where coalesce(r.data->>'destinationAccountId', '') = m.old_id::text
      and m.old_id <> m.new_id;
  end if;

  update public.app_settings s
  set data = jsonb_set(
    coalesce(s.data, '{}'::jsonb),
    '{accounting_accounts}',
    (
      select coalesce(
        jsonb_object_agg(e.key, coalesce((select m.new_id::text from tmp_destination_account_map m where m.old_id::text = e.value limit 1), e.value)),
        '{}'::jsonb
      )
      from jsonb_each_text(coalesce(s.data->'accounting_accounts', '{}'::jsonb)) e
    ),
    true
  )
  where s.id in ('app', 'singleton');

  update public.chart_of_accounts a
  set is_active = false
  where a.id in (
    select m.old_id
    from tmp_destination_account_map m
    where m.old_id <> m.new_id
  );
end $$;

notify pgrst, 'reload schema';
