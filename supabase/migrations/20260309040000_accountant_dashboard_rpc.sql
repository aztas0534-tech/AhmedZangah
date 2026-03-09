-- Unified Accountant Dashboard Summary RPC
-- Provides sales, purchases, AR/AP, and GL trial balance data alongside shift reconciliation

CREATE OR REPLACE FUNCTION public.get_accountant_dashboard_summary(
    p_start_date timestamptz DEFAULT NULL,
    p_end_date   timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result jsonb;
    v_sales  jsonb;
    v_purchases jsonb;
    v_parties jsonb;
    v_trial_balance jsonb;
    v_start  timestamptz := coalesce(p_start_date, date_trunc('month', now()));
    v_end    timestamptz := coalesce(p_end_date, now());
    v_role   text;
BEGIN
    -- Permission check
    SELECT role INTO v_role FROM public.admin_users WHERE auth_user_id = auth.uid() AND is_active;
    IF v_role IS NULL OR v_role NOT IN ('owner','manager','accountant') THEN
        IF NOT public.has_admin_permission('accounting.view') THEN
            RAISE EXCEPTION 'غير مصرح';
        END IF;
    END IF;

    -- 1. SALES SUMMARY (from orders)
    SELECT jsonb_build_object(
        'total_orders', count(*)::int,
        'delivered_orders', count(*) FILTER (WHERE status IN ('delivered','completed'))::int,
        'cancelled_orders', count(*) FILTER (WHERE status = 'cancelled')::int,
        'pending_orders', count(*) FILTER (WHERE status NOT IN ('delivered','completed','cancelled','returned'))::int,
        'returned_orders', count(*) FILTER (WHERE status = 'returned')::int,
        'total_sales', coalesce(sum(coalesce(nullif((data->>'total')::numeric, null), 0))
                       FILTER (WHERE status NOT IN ('cancelled','returned')), 0),
        'total_tax', coalesce(sum(coalesce(nullif((data->>'taxAmount')::numeric, null), 0))
                     FILTER (WHERE status NOT IN ('cancelled','returned')), 0),
        'total_discount', coalesce(sum(coalesce(nullif((data->>'discount')::numeric, null), 0))
                          FILTER (WHERE status NOT IN ('cancelled','returned')), 0),
        'by_payment_method', (
            SELECT coalesce(jsonb_object_agg(
                coalesce(NULLIF(TRIM(data->>'paymentMethod'), ''), 'unknown'),
                jsonb_build_object(
                    'count', sub.cnt,
                    'total', sub.total
                )
            ), '{}'::jsonb)
            FROM (
                SELECT
                    coalesce(NULLIF(TRIM(data->>'paymentMethod'), ''), 'unknown') AS method,
                    count(*)::int AS cnt,
                    coalesce(sum(coalesce(nullif((data->>'total')::numeric, null), 0)), 0) AS total
                FROM public.orders
                WHERE created_at >= v_start AND created_at <= v_end
                  AND status NOT IN ('cancelled','returned')
                GROUP BY method
            ) sub
        ),
        'by_source', (
            SELECT coalesce(jsonb_object_agg(
                coalesce(NULLIF(TRIM(data->>'orderSource'), ''), 'unknown'),
                jsonb_build_object('count', sub.cnt, 'total', sub.total)
            ), '{}'::jsonb)
            FROM (
                SELECT
                    coalesce(NULLIF(TRIM(data->>'orderSource'), ''), 'unknown') AS src,
                    count(*)::int AS cnt,
                    coalesce(sum(coalesce(nullif((data->>'total')::numeric, null), 0)), 0) AS total
                FROM public.orders
                WHERE created_at >= v_start AND created_at <= v_end
                  AND status NOT IN ('cancelled','returned')
                GROUP BY src
            ) sub
        )
    )
    INTO v_sales
    FROM public.orders
    WHERE created_at >= v_start AND created_at <= v_end;

    -- 2. PURCHASES SUMMARY (from purchase_orders)
    SELECT jsonb_build_object(
        'total_pos', count(*)::int,
        'completed_pos', count(*) FILTER (WHERE status = 'completed')::int,
        'draft_pos', count(*) FILTER (WHERE status = 'draft')::int,
        'cancelled_pos', count(*) FILTER (WHERE status = 'cancelled')::int,
        'total_amount', coalesce(sum(total_amount) FILTER (WHERE status != 'cancelled'), 0),
        'total_paid', coalesce(sum(paid_amount) FILTER (WHERE status != 'cancelled'), 0),
        'total_unpaid', coalesce(sum(total_amount - paid_amount) FILTER (WHERE status != 'cancelled'), 0),
        'by_supplier', (
            SELECT coalesce(jsonb_agg(
                jsonb_build_object(
                    'supplier_id', sub.supplier_id,
                    'supplier_name', sub.supplier_name,
                    'count', sub.cnt,
                    'total', sub.total,
                    'paid', sub.paid
                ) ORDER BY sub.total DESC
            ), '[]'::jsonb)
            FROM (
                SELECT
                    po.supplier_id,
                    coalesce(s.name, 'بدون مورد') AS supplier_name,
                    count(*)::int AS cnt,
                    coalesce(sum(po.total_amount), 0) AS total,
                    coalesce(sum(po.paid_amount), 0) AS paid
                FROM public.purchase_orders po
                LEFT JOIN public.suppliers s ON s.id = po.supplier_id
                WHERE po.created_at >= v_start AND po.created_at <= v_end
                  AND po.status != 'cancelled'
                GROUP BY po.supplier_id, s.name
                ORDER BY total DESC
                LIMIT 20
            ) sub
        )
    )
    INTO v_purchases
    FROM public.purchase_orders
    WHERE created_at >= v_start AND created_at <= v_end;

    -- 3. AR/AP SUMMARY (from financial_parties + journal_lines)
    SELECT jsonb_build_object(
        'total_customers', count(*) FILTER (WHERE party_type = 'customer')::int,
        'total_suppliers', count(*) FILTER (WHERE party_type = 'supplier')::int,
        'total_employees', count(*) FILTER (WHERE party_type = 'employee')::int,
        'ar_balance', (
            SELECT coalesce(sum(jl.debit - jl.credit), 0)
            FROM public.journal_lines jl
            JOIN public.journal_entries je ON je.id = jl.journal_entry_id
            JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
            WHERE coa.code = '1200'
        ),
        'ap_balance', (
            SELECT coalesce(sum(jl.credit - jl.debit), 0)
            FROM public.journal_lines jl
            JOIN public.journal_entries je ON je.id = jl.journal_entry_id
            JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
            WHERE coa.code = '2010'
        ),
        'top_debtors', (
            SELECT coalesce(jsonb_agg(
                jsonb_build_object(
                    'name', sub.name,
                    'party_type', sub.party_type,
                    'balance', sub.balance
                ) ORDER BY sub.balance DESC
            ), '[]'::jsonb)
            FROM (
                SELECT
                    fp.name,
                    fp.party_type,
                    coalesce(sum(jl.debit - jl.credit), 0) AS balance
                FROM public.financial_parties fp
                JOIN public.financial_party_links fpl ON fpl.party_id = fp.id
                JOIN public.journal_lines jl ON jl.line_memo LIKE '%' || fp.id::text || '%'
                   OR jl.line_memo LIKE '%' || fpl.linked_entity_id || '%'
                WHERE fp.is_active
                GROUP BY fp.id, fp.name, fp.party_type
                HAVING sum(jl.debit - jl.credit) > 0
                ORDER BY balance DESC
                LIMIT 10
            ) sub
        ),
        'top_creditors', (
            SELECT coalesce(jsonb_agg(
                jsonb_build_object(
                    'name', sub.name,
                    'party_type', sub.party_type,
                    'balance', sub.balance
                ) ORDER BY sub.balance DESC
            ), '[]'::jsonb)
            FROM (
                SELECT
                    fp.name,
                    fp.party_type,
                    coalesce(sum(jl.credit - jl.debit), 0) AS balance
                FROM public.financial_parties fp
                JOIN public.financial_party_links fpl ON fpl.party_id = fp.id
                JOIN public.journal_lines jl ON jl.line_memo LIKE '%' || fp.id::text || '%'
                   OR jl.line_memo LIKE '%' || fpl.linked_entity_id || '%'
                WHERE fp.is_active
                GROUP BY fp.id, fp.name, fp.party_type
                HAVING sum(jl.credit - jl.debit) > 0
                ORDER BY balance DESC
                LIMIT 10
            ) sub
        )
    )
    INTO v_parties
    FROM public.financial_parties
    WHERE is_active;

    -- 4. TRIAL BALANCE (from chart_of_accounts + journal_lines)
    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'code', sub.code,
            'name', sub.name,
            'account_type', sub.account_type,
            'total_debit', sub.total_debit,
            'total_credit', sub.total_credit,
            'balance', sub.balance
        ) ORDER BY sub.code
    ), '[]'::jsonb)
    INTO v_trial_balance
    FROM (
        SELECT
            coa.code,
            coa.name,
            coa.account_type,
            coalesce(sum(jl.debit), 0) AS total_debit,
            coalesce(sum(jl.credit), 0) AS total_credit,
            CASE
                WHEN coa.normal_balance = 'debit'
                THEN coalesce(sum(jl.debit - jl.credit), 0)
                ELSE coalesce(sum(jl.credit - jl.debit), 0)
            END AS balance
        FROM public.chart_of_accounts coa
        LEFT JOIN public.journal_lines jl ON jl.account_id = coa.id
        LEFT JOIN public.journal_entries je ON je.id = jl.journal_entry_id
            AND je.entry_date >= v_start AND je.entry_date <= v_end
        WHERE coa.is_active
        GROUP BY coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance
        HAVING coalesce(sum(jl.debit), 0) > 0 OR coalesce(sum(jl.credit), 0) > 0
    ) sub;

    v_result := jsonb_build_object(
        'period_start', v_start,
        'period_end', v_end,
        'sales', v_sales,
        'purchases', v_purchases,
        'parties', v_parties,
        'trial_balance', v_trial_balance
    );

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_accountant_dashboard_summary(timestamptz, timestamptz) FROM public;
GRANT EXECUTE ON FUNCTION public.get_accountant_dashboard_summary(timestamptz, timestamptz) TO authenticated;

NOTIFY pgrst, 'reload schema';
