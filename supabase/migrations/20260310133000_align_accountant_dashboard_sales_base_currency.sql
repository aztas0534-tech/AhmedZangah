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
    v_sales  jsonb;
    v_purchases jsonb;
    v_parties jsonb;
    v_trial_balance jsonb;
    v_start  timestamptz := coalesce(p_start_date, date_trunc('month', now()));
    v_end    timestamptz := coalesce(p_end_date, now());
    v_role   text;
begin
    select role into v_role from public.admin_users where auth_user_id = auth.uid() and is_active;
    if v_role is null or v_role not in ('owner','manager','accountant') then
        if not public.has_admin_permission('accounting.view') then
            raise exception 'غير مصرح';
        end if;
    end if;

    with effective_orders as (
        select
            o.id,
            o.status::text as status,
            o.data,
            o.created_at,
            nullif(o.data->>'paidAt', '')::timestamptz as paid_at,
            coalesce(nullif(o.data->>'paymentMethod', ''), 'unknown') as payment_method,
            coalesce(nullif(o.data->>'orderSource', ''), 'unknown') as order_source,
            coalesce(
                nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
                nullif(o.data->>'paidAt', '')::timestamptz,
                nullif(o.data->>'deliveredAt', '')::timestamptz,
                o.created_at
            ) as date_by,
            public.order_fx_rate(
                coalesce(
                    nullif(btrim(coalesce(o.currency, '')), ''),
                    nullif(btrim(coalesce(o.data->>'currency', '')), ''),
                    public.get_base_currency()
                ),
                coalesce(
                    nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
                    nullif(o.data->>'paidAt', '')::timestamptz,
                    nullif(o.data->>'deliveredAt', '')::timestamptz,
                    o.created_at
                ),
                o.fx_rate
            ) as fx_rate_effective,
            coalesce(
                o.base_total,
                coalesce(public.safe_cast_numeric(o.data->>'total'), 0) * public.order_fx_rate(
                    coalesce(
                        nullif(btrim(coalesce(o.currency, '')), ''),
                        nullif(btrim(coalesce(o.data->>'currency', '')), ''),
                        public.get_base_currency()
                    ),
                    coalesce(
                        nullif(o.data->'invoiceSnapshot'->>'issuedAt', '')::timestamptz,
                        nullif(o.data->>'paidAt', '')::timestamptz,
                        nullif(o.data->>'deliveredAt', '')::timestamptz,
                        o.created_at
                    ),
                    o.fx_rate
                )
            ) as total_base
        from public.orders o
        where nullif(trim(coalesce(o.data->>'voidedAt','')), '') is null
    ),
    ranged_orders as (
        select
            eo.*,
            (coalesce(public.safe_cast_numeric(eo.data->>'taxAmount'), 0) * eo.fx_rate_effective) as tax_base,
            (coalesce(public.safe_cast_numeric(eo.data->>'discountAmount'), public.safe_cast_numeric(eo.data->>'discount'), 0) * eo.fx_rate_effective) as discount_base
        from effective_orders eo
        where eo.date_by >= v_start and eo.date_by <= v_end
    )
    select jsonb_build_object(
        'total_orders', count(*)::int,
        'delivered_orders', count(*) filter (where status in ('delivered','completed'))::int,
        'cancelled_orders', count(*) filter (where status = 'cancelled')::int,
        'pending_orders', count(*) filter (where status not in ('delivered','completed','cancelled','returned'))::int,
        'returned_orders', count(*) filter (where status = 'returned')::int,
        'total_sales', coalesce(sum(total_base) filter (where status not in ('cancelled','returned')), 0),
        'total_tax', coalesce(sum(tax_base) filter (where status not in ('cancelled','returned')), 0),
        'total_discount', coalesce(sum(discount_base) filter (where status not in ('cancelled','returned')), 0),
        'by_payment_method', (
            select coalesce(jsonb_object_agg(
                sub.method,
                jsonb_build_object('count', sub.cnt, 'total', sub.total)
            ), '{}'::jsonb)
            from (
                select
                    coalesce(nullif(trim(payment_method), ''), 'unknown') as method,
                    count(*)::int as cnt,
                    coalesce(sum(total_base), 0) as total
                from ranged_orders
                where status not in ('cancelled','returned')
                group by 1
            ) sub
        ),
        'by_source', (
            select coalesce(jsonb_object_agg(
                sub.src,
                jsonb_build_object('count', sub.cnt, 'total', sub.total)
            ), '{}'::jsonb)
            from (
                select
                    coalesce(nullif(trim(order_source), ''), 'unknown') as src,
                    count(*)::int as cnt,
                    coalesce(sum(total_base), 0) as total
                from ranged_orders
                where status not in ('cancelled','returned')
                group by 1
            ) sub
        )
    ) into v_sales
    from ranged_orders;

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
    ) into v_purchases
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
        ),
        'ap_balance', (
            select coalesce(sum(jl.credit - jl.debit), 0)
            from public.journal_lines jl
            join public.journal_entries je on je.id = jl.journal_entry_id
            join public.chart_of_accounts coa on coa.id = jl.account_id
            where coa.code = '2010'
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
                    latest.running_balance as balance
                from public.financial_parties fp
                join lateral (
                    select ple.running_balance
                    from public.party_ledger_entries ple
                    join public.party_subledger_accounts psa
                      on psa.account_id = ple.account_id and psa.role = 'ar'
                    where ple.party_id = fp.id
                    order by ple.occurred_at desc, ple.created_at desc, ple.id desc
                    limit 1
                ) latest on true
                where fp.is_active
                  and latest.running_balance > 0.01
                order by latest.running_balance desc
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
                    latest.running_balance as balance
                from public.financial_parties fp
                join lateral (
                    select ple.running_balance
                    from public.party_ledger_entries ple
                    join public.party_subledger_accounts psa
                      on psa.account_id = ple.account_id and psa.role = 'ap'
                    where ple.party_id = fp.id
                    order by ple.occurred_at desc, ple.created_at desc, ple.id desc
                    limit 1
                ) latest on true
                where fp.is_active
                  and latest.running_balance > 0.01
                order by latest.running_balance desc
                limit 10
            ) sub
        )
    ) into v_parties
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
            coalesce(sum(jl.debit), 0) as total_debit,
            coalesce(sum(jl.credit), 0) as total_credit,
            case
                when coa.normal_balance = 'debit'
                then coalesce(sum(jl.debit - jl.credit), 0)
                else coalesce(sum(jl.credit - jl.debit), 0)
            end as balance
        from public.chart_of_accounts coa
        left join (
            select jl2.account_id, jl2.debit, jl2.credit
            from public.journal_lines jl2
            join public.journal_entries je2 on je2.id = jl2.journal_entry_id
            where je2.entry_date >= v_start and je2.entry_date <= v_end
        ) jl on jl.account_id = coa.id
        where coa.is_active
        group by coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance
        having coalesce(sum(jl.debit), 0) > 0 or coalesce(sum(jl.credit), 0) > 0
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
