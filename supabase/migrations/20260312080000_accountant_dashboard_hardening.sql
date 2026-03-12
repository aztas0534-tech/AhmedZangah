create or replace function public.get_accountant_dashboard_summary(
    p_start_date timestamptz default null,
    p_end_date   timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_result jsonb;
    v_sales jsonb;
    v_purchases jsonb;
    v_parties jsonb;
    v_trial_balance jsonb;
    v_start timestamptz := coalesce(p_start_date, date_trunc('month', now()));
    v_end timestamptz := coalesce(p_end_date, now());
    v_role text;
begin
    if v_start > v_end then
        raise exception 'invalid date range';
    end if;

    select role into v_role
    from public.admin_users
    where auth_user_id = auth.uid()
      and is_active;

    if v_role is null or v_role not in ('owner', 'manager', 'accountant') then
        if not public.has_admin_permission('accounting.view') then
            raise exception 'غير مصرح';
        end if;
    end if;

    select jsonb_build_object(
        'total_orders', count(*)::int,
        'delivered_orders', count(*) filter (where status in ('delivered', 'completed'))::int,
        'cancelled_orders', count(*) filter (where status = 'cancelled')::int,
        'pending_orders', count(*) filter (where status not in ('delivered', 'completed', 'cancelled', 'returned'))::int,
        'returned_orders', count(*) filter (where status = 'returned')::int,
        'total_sales', coalesce(sum(coalesce(nullif((data->>'total')::numeric, null), 0)) filter (where status not in ('cancelled', 'returned')), 0),
        'total_tax', coalesce(sum(coalesce(nullif((data->>'taxAmount')::numeric, null), 0)) filter (where status not in ('cancelled', 'returned')), 0),
        'total_discount', coalesce(sum(coalesce(nullif((data->>'discount')::numeric, null), 0)) filter (where status not in ('cancelled', 'returned')), 0)
    )
    into v_sales
    from public.orders
    where created_at >= v_start and created_at <= v_end;

    v_sales := v_sales || jsonb_build_object('by_payment_method', (
        select coalesce(jsonb_object_agg(
            sub.method,
            jsonb_build_object('count', sub.cnt, 'total', sub.total)
        ), '{}'::jsonb)
        from (
            select
                coalesce(nullif(trim(data->>'paymentMethod'), ''), 'unknown') as method,
                count(*)::int as cnt,
                coalesce(sum(coalesce(nullif((data->>'total')::numeric, null), 0)), 0) as total
            from public.orders
            where created_at >= v_start and created_at <= v_end
              and status not in ('cancelled', 'returned')
            group by 1
        ) sub
    ));

    v_sales := v_sales || jsonb_build_object('by_source', (
        select coalesce(jsonb_object_agg(
            sub.src,
            jsonb_build_object('count', sub.cnt, 'total', sub.total)
        ), '{}'::jsonb)
        from (
            select
                coalesce(nullif(trim(data->>'orderSource'), ''), 'unknown') as src,
                count(*)::int as cnt,
                coalesce(sum(coalesce(nullif((data->>'total')::numeric, null), 0)), 0) as total
            from public.orders
            where created_at >= v_start and created_at <= v_end
              and status not in ('cancelled', 'returned')
            group by 1
        ) sub
    ));

    select jsonb_build_object(
        'total_pos', count(*)::int,
        'completed_pos', count(*) filter (where status = 'completed')::int,
        'draft_pos', count(*) filter (where status = 'draft')::int,
        'cancelled_pos', count(*) filter (where status = 'cancelled')::int,
        'total_amount', coalesce(sum(total_amount) filter (where status != 'cancelled'), 0),
        'total_paid', coalesce(sum(paid_amount) filter (where status != 'cancelled'), 0),
        'total_unpaid', coalesce(sum(total_amount - paid_amount) filter (where status != 'cancelled'), 0),
        'by_supplier', (
            select coalesce(jsonb_agg(
                jsonb_build_object(
                    'supplier_id', sub.supplier_id,
                    'supplier_name', sub.supplier_name,
                    'count', sub.cnt,
                    'total', sub.total,
                    'paid', sub.paid
                ) order by sub.total desc
            ), '[]'::jsonb)
            from (
                select
                    po.supplier_id,
                    coalesce(s.name, 'بدون مورد') as supplier_name,
                    count(*)::int as cnt,
                    coalesce(sum(po.total_amount), 0) as total,
                    coalesce(sum(po.paid_amount), 0) as paid
                from public.purchase_orders po
                left join public.suppliers s on s.id = po.supplier_id
                where po.created_at >= v_start and po.created_at <= v_end
                  and po.status != 'cancelled'
                group by po.supplier_id, s.name
                order by total desc
                limit 20
            ) sub
        )
    )
    into v_purchases
    from public.purchase_orders
    where created_at >= v_start and created_at <= v_end;

    select jsonb_build_object(
        'total_customers', count(*) filter (where party_type = 'customer')::int,
        'total_suppliers', count(*) filter (where party_type = 'supplier')::int,
        'total_employees', count(*) filter (where party_type = 'employee')::int,
        'ar_balance', (
            select coalesce(sum(jl.debit - jl.credit), 0)
            from public.journal_lines jl
            join public.journal_entries je on je.id = jl.journal_entry_id
            join public.chart_of_accounts coa on coa.id = jl.account_id
            where coa.code = '1200'
              and je.status = 'posted'
              and je.entry_date >= v_start::date
              and je.entry_date <= v_end::date
        ),
        'ap_balance', (
            select coalesce(sum(jl.credit - jl.debit), 0)
            from public.journal_lines jl
            join public.journal_entries je on je.id = jl.journal_entry_id
            join public.chart_of_accounts coa on coa.id = jl.account_id
            where coa.code = '2010'
              and je.status = 'posted'
              and je.entry_date >= v_start::date
              and je.entry_date <= v_end::date
        ),
        'top_debtors', (
            select coalesce(jsonb_agg(
                jsonb_build_object(
                    'name', sub.name,
                    'party_type', sub.party_type,
                    'balance', sub.balance
                ) order by sub.balance desc
            ), '[]'::jsonb)
            from (
                select
                    fp.name,
                    fp.party_type,
                    coalesce(sum(jl.debit - jl.credit), 0) as balance
                from public.financial_parties fp
                join public.journal_lines jl on jl.party_id = fp.id
                join public.journal_entries je on je.id = jl.journal_entry_id
                where fp.is_active
                  and je.status = 'posted'
                  and je.entry_date >= v_start::date
                  and je.entry_date <= v_end::date
                group by fp.id, fp.name, fp.party_type
                having sum(jl.debit - jl.credit) > 0
                order by balance desc
                limit 10
            ) sub
        ),
        'top_creditors', (
            select coalesce(jsonb_agg(
                jsonb_build_object(
                    'name', sub.name,
                    'party_type', sub.party_type,
                    'balance', sub.balance
                ) order by sub.balance desc
            ), '[]'::jsonb)
            from (
                select
                    fp.name,
                    fp.party_type,
                    coalesce(sum(jl.credit - jl.debit), 0) as balance
                from public.financial_parties fp
                join public.journal_lines jl on jl.party_id = fp.id
                join public.journal_entries je on je.id = jl.journal_entry_id
                where fp.is_active
                  and je.status = 'posted'
                  and je.entry_date >= v_start::date
                  and je.entry_date <= v_end::date
                group by fp.id, fp.name, fp.party_type
                having sum(jl.credit - jl.debit) > 0
                order by balance desc
                limit 10
            ) sub
        )
    )
    into v_parties
    from public.financial_parties
    where is_active;

    select coalesce(jsonb_agg(
        jsonb_build_object(
            'code', sub.code,
            'name', sub.name,
            'account_type', sub.account_type,
            'total_debit', sub.total_debit,
            'total_credit', sub.total_credit,
            'balance', sub.balance
        ) order by sub.code
    ), '[]'::jsonb)
    into v_trial_balance
    from (
        select
            coa.code,
            coa.name,
            coa.account_type,
            coalesce(sum(case when je.id is not null then jl.debit else 0 end), 0) as total_debit,
            coalesce(sum(case when je.id is not null then jl.credit else 0 end), 0) as total_credit,
            case
                when coa.normal_balance = 'debit'
                then coalesce(sum(case when je.id is not null then (jl.debit - jl.credit) else 0 end), 0)
                else coalesce(sum(case when je.id is not null then (jl.credit - jl.debit) else 0 end), 0)
            end as balance
        from public.chart_of_accounts coa
        left join public.journal_lines jl on jl.account_id = coa.id
        left join public.journal_entries je on je.id = jl.journal_entry_id
          and je.status = 'posted'
          and je.entry_date >= v_start::date
          and je.entry_date <= v_end::date
        where coa.is_active
        group by coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance
        having coalesce(sum(case when je.id is not null then jl.debit else 0 end), 0) > 0
            or coalesce(sum(case when je.id is not null then jl.credit else 0 end), 0) > 0
    ) sub;

    v_result := jsonb_build_object(
        'period_start', v_start,
        'period_end', v_end,
        'sales', v_sales,
        'purchases', v_purchases,
        'parties', v_parties,
        'trial_balance', v_trial_balance
    );

    return v_result;
end;
$$;

revoke all on function public.get_accountant_dashboard_summary(timestamptz, timestamptz) from public;
grant execute on function public.get_accountant_dashboard_summary(timestamptz, timestamptz) to authenticated;

notify pgrst, 'reload schema';
