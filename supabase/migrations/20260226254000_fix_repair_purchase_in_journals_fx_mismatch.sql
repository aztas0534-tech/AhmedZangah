set app.allow_ledger_ddl = '1';

create or replace function public.repair_purchase_in_journals_from_movements(
  p_start timestamptz default null,
  p_end timestamptz default null,
  p_limit int default 500,
  p_dry_run boolean default true
)
returns table(
  journal_entry_id uuid,
  movement_id uuid,
  old_total_cost numeric,
  new_total_cost numeric,
  action text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_line_count int;
  v_debit_lines int;
  v_credit_lines int;
  v_debit_line_id uuid;
  v_credit_line_id uuid;
  v_old_debit numeric;
  v_old_credit numeric;
  v_old_total numeric;
  v_base text;
  v_je_currency text;
  v_je_fx numeric;
  v_je_foreign numeric;
begin
  if not public.has_admin_permission('accounting.manage') then
    raise exception 'not allowed';
  end if;

  p_limit := greatest(1, least(coalesce(p_limit, 500), 5000));
  v_base := public.get_base_currency();

  if not coalesce(p_dry_run, true) then
    perform set_config('app.allow_ledger_ddl', '1', true);
    alter table public.journal_entries disable trigger user;
    alter table public.journal_lines disable trigger user;
  end if;

  begin
    for r in
      select
        je.id as entry_id,
        im.id as movement_id,
        coalesce(im.total_cost, 0) as mv_total_cost
      from public.journal_entries je
      join public.inventory_movements im
        on je.source_table = 'inventory_movements'
       and je.source_id = im.id::text
       and je.source_event = 'purchase_in'
      where je.status = 'posted'
        and im.movement_type = 'purchase_in'
        and (p_start is null or im.occurred_at >= p_start)
        and (p_end is null or im.occurred_at <= p_end)
      order by im.occurred_at desc, im.id desc
      limit p_limit
    loop
      select
        count(*)::int,
        sum(case when coalesce(jl.debit, 0) > 0 then 1 else 0 end)::int,
        sum(case when coalesce(jl.credit, 0) > 0 then 1 else 0 end)::int
      into
        v_line_count,
        v_debit_lines,
        v_credit_lines
      from public.journal_lines jl
      where jl.journal_entry_id = r.entry_id;

      v_debit_line_id := null;
      v_credit_line_id := null;
      v_old_debit := null;
      v_old_credit := null;

      select jl.id, jl.debit
      into v_debit_line_id, v_old_debit
      from public.journal_lines jl
      where jl.journal_entry_id = r.entry_id
        and coalesce(jl.debit, 0) > 0
      order by jl.created_at asc, jl.id asc
      limit 1;

      select jl.id, jl.credit
      into v_credit_line_id, v_old_credit
      from public.journal_lines jl
      where jl.journal_entry_id = r.entry_id
        and coalesce(jl.credit, 0) > 0
      order by jl.created_at asc, jl.id asc
      limit 1;

      v_old_total := greatest(coalesce(v_old_debit, 0), coalesce(v_old_credit, 0));

      if v_line_count <> 2 or v_debit_lines <> 1 or v_credit_lines <> 1 or v_debit_line_id is null or v_credit_line_id is null then
        journal_entry_id := r.entry_id;
        movement_id := r.movement_id;
        old_total_cost := v_old_total;
        new_total_cost := r.mv_total_cost;
        action := 'skipped_complex';
        return next;
        continue;
      end if;

      if abs(coalesce(v_old_total, 0) - coalesce(r.mv_total_cost, 0))
          <= greatest(0.01, abs(coalesce(r.mv_total_cost, 0)) * 0.01) then
        continue;
      end if;

      if coalesce(p_dry_run, true) then
        journal_entry_id := r.entry_id;
        movement_id := r.movement_id;
        old_total_cost := v_old_total;
        new_total_cost := r.mv_total_cost;
        action := 'dry_run';
        return next;
        continue;
      end if;

      update public.journal_lines
      set debit = r.mv_total_cost
      where id = v_debit_line_id;

      update public.journal_lines
      set credit = r.mv_total_cost
      where id = v_credit_line_id;

      select
        upper(nullif(btrim(coalesce(je.currency_code, '')), '')) as currency_code,
        coalesce(je.fx_rate, 0) as fx_rate,
        coalesce(je.foreign_amount, 0) as foreign_amount
      into v_je_currency, v_je_fx, v_je_foreign
      from public.journal_entries je
      where je.id = r.entry_id;

      if v_je_currency is not null
         and v_je_currency <> upper(v_base)
         and v_je_fx > 0
         and v_je_foreign > 0 then
        update public.journal_entries
        set foreign_amount = round(coalesce(r.mv_total_cost, 0) / nullif(v_je_fx, 0), 6)
        where id = r.entry_id;
      end if;

      perform public.check_journal_entry_balance(r.entry_id);

      journal_entry_id := r.entry_id;
      movement_id := r.movement_id;
      old_total_cost := v_old_total;
      new_total_cost := r.mv_total_cost;
      action := 'fixed';
      return next;
    end loop;
  exception when others then
    if not coalesce(p_dry_run, true) then
      alter table public.journal_lines enable trigger user;
      alter table public.journal_entries enable trigger user;
    end if;
    raise;
  end;

  if not coalesce(p_dry_run, true) then
    alter table public.journal_lines enable trigger user;
    alter table public.journal_entries enable trigger user;
  end if;
end;
$$;

revoke all on function public.repair_purchase_in_journals_from_movements(timestamptz, timestamptz, int, boolean) from public;
grant execute on function public.repair_purchase_in_journals_from_movements(timestamptz, timestamptz, int, boolean) to authenticated;

notify pgrst, 'reload schema';
