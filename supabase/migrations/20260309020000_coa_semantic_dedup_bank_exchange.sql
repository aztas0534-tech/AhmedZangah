set app.allow_ledger_ddl = '1';

do $$
declare
  v_rec record;
  v_target_code text;
  v_parent_code text;
  v_parent_id uuid;
  v_idx int;
  v_group_no int;
  v_cur text;
begin
  for v_rec in
    select id, code, name, account_type, normal_balance, is_active
    from public.chart_of_accounts
    where code ~ '^(YER|USD|SAR)-(1020|1030)-[0-9]{3}$'
  loop
    v_target_code := concat(split_part(v_rec.code, '-', 2), '-', split_part(v_rec.code, '-', 3), '-', split_part(v_rec.code, '-', 1));
    v_parent_code := split_part(v_rec.code, '-', 2);
    select id into v_parent_id from public.chart_of_accounts where code = v_parent_code limit 1;

    insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active, parent_id)
    values (v_target_code, v_rec.name, v_rec.account_type, v_rec.normal_balance, true, v_parent_id)
    on conflict (code) do update
      set name = excluded.name,
          account_type = excluded.account_type,
          normal_balance = excluded.normal_balance,
          is_active = true,
          parent_id = coalesce(public.chart_of_accounts.parent_id, excluded.parent_id);

    if not exists (select 1 from public.journal_lines jl where jl.account_id = v_rec.id) then
      update public.chart_of_accounts set is_active = false where id = v_rec.id;
    end if;
  end loop;

  for v_rec in
    select id, code, name, account_type, normal_balance, is_active
    from public.chart_of_accounts
    where code ~ '^(1020|1030)\.[0-9]+$'
  loop
    v_idx := split_part(v_rec.code, '.', 2)::int;
    if v_idx is null or v_idx <= 0 then
      continue;
    end if;
    v_group_no := ((v_idx - 1) / 3) + 1;
    v_cur := case ((v_idx - 1) % 3)
      when 0 then 'YER'
      when 1 then 'SAR'
      else 'USD'
    end;
    v_parent_code := split_part(v_rec.code, '.', 1);
    v_target_code := concat(v_parent_code, '-', lpad(v_group_no::text, 3, '0'), '-', v_cur);
    select id into v_parent_id from public.chart_of_accounts where code = v_parent_code limit 1;

    insert into public.chart_of_accounts(code, name, account_type, normal_balance, is_active, parent_id)
    values (v_target_code, v_rec.name, v_rec.account_type, v_rec.normal_balance, true, v_parent_id)
    on conflict (code) do update
      set is_active = true,
          parent_id = coalesce(public.chart_of_accounts.parent_id, excluded.parent_id);

    if not exists (select 1 from public.journal_lines jl where jl.account_id = v_rec.id) then
      update public.chart_of_accounts set is_active = false where id = v_rec.id;
    end if;
  end loop;
end $$;

create or replace function public.list_chart_of_accounts(p_include_inactive boolean default true)
returns table(
  id uuid,
  code text,
  name text,
  account_type text,
  normal_balance text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_permission('accounting.view') then
    raise exception 'not allowed';
  end if;

  return query
  with src as (
    select
      coa.*,
      (
        coa.code ~ '^(1020|1030)-[0-9]{3}-(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)$'
      ) as is_canonical,
      (
        coa.code ~ '^(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)-(1020|1030)-[0-9]{3}$'
      ) as is_prefixed,
      (
        coa.code ~ '^(1020|1030)\\.[0-9]+$'
      ) as is_dot,
      (
        coa.code ~ '^(1020|1030)(-|\\.|$)'
        or coa.code ~ '^(YER|USD|SAR|AED|EGP|EUR|GBP|KWD|QAR|OMR|BHD|JOD|CNY)-(1020|1030)-'
      ) as is_bank_family
    from public.chart_of_accounts coa
    where p_include_inactive = true or coa.is_active = true
  ),
  keying as (
    select
      s.*,
      case
        when s.is_canonical then s.code
        when s.is_prefixed then concat(split_part(s.code,'-',2), '-', split_part(s.code,'-',3), '-', split_part(s.code,'-',1))
        when s.is_dot then
          concat(
            split_part(s.code,'.',1),
            '-',
            lpad((((split_part(s.code,'.',2)::int - 1) / 3) + 1)::text, 3, '0'),
            '-',
            case ((split_part(s.code,'.',2)::int - 1) % 3)
              when 0 then 'YER'
              when 1 then 'SAR'
              else 'USD'
            end
          )
        else s.id::text
      end as semantic_key
    from src s
  ),
  ranked as (
    select
      k.*,
      row_number() over (
        partition by case when k.is_bank_family then k.semantic_key else k.id::text end
        order by
          case
            when k.is_canonical then 1
            when k.is_prefixed then 2
            when k.is_dot then 3
            else 4
          end,
          k.is_active desc,
          k.created_at asc,
          k.id asc
      ) as rn
    from keying k
  )
  select
    r.id,
    r.code,
    r.name,
    r.account_type,
    r.normal_balance,
    r.is_active,
    r.created_at
  from ranked r
  where r.rn = 1
  order by r.code asc;
end;
$$;

revoke all on function public.list_chart_of_accounts(boolean) from public;
grant execute on function public.list_chart_of_accounts(boolean) to authenticated;

notify pgrst, 'reload schema';
