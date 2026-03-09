-- Fix Accountant Dashboard RPC:
-- 1. Trial Balance: fix LEFT JOIN date filter (was not filtering by period)
-- 2. Top Debtors/Creditors: replace LIKE on line_memo with party_ledger_entries

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
    v_sales := jsonb_build_object(
        'total_orders', 0, 'delivered_orders', 0, 'cancelled_orders', 0,
        'pending_orders', 0, 'returned_orders', 0,
        'total_sales', 0, 'total_tax', 0, 'total_discount', 0,
        'by_payment_method', '{}'::jsonb, 'by_source', '{}'::jsonb
    );

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
                          FILTER (WHERE status NOT IN ('cancelled','returned')), 0)
    )
    INTO v_sales
    FROM public.orders
    WHERE created_at >= v_start AND created_at <= v_end;

    -- Sales by payment method
    v_sales := v_sales || jsonb_build_object('by_payment_method', (
        SELECT coalesce(jsonb_object_agg(
            sub.method,
            jsonb_build_object('count', sub.cnt, 'total', sub.total)
        ), '{}'::jsonb)
        FROM (
            SELECT
                coalesce(NULLIF(TRIM(data->>'paymentMethod'), ''), 'unknown') AS method,
                count(*)::int AS cnt,
                coalesce(sum(coalesce(nullif((data->>'total')::numeric, null), 0)), 0) AS total
            FROM public.orders
            WHERE created_at >= v_start AND created_at <= v_end
              AND status NOT IN ('cancelled','returned')
            GROUP BY 1
        ) sub
    ));

    -- Sales by source
    v_sales := v_sales || jsonb_build_object('by_source', (
        SELECT coalesce(jsonb_object_agg(
            sub.src,
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
            GROUP BY 1
        ) sub
    ));

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

    -- 3. AR/AP SUMMARY — uses party_ledger_entries for accurate balances
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
                    latest.running_balance AS balance
                FROM public.financial_parties fp
                JOIN LATERAL (
                    SELECT ple.running_balance
                    FROM public.party_ledger_entries ple
                    JOIN public.party_subledger_accounts psa
                      ON psa.account_id = ple.account_id AND psa.role = 'ar'
                    WHERE ple.party_id = fp.id
                    ORDER BY ple.occurred_at DESC, ple.created_at DESC, ple.id DESC
                    LIMIT 1
                ) latest ON true
                WHERE fp.is_active
                  AND latest.running_balance > 0.01
                ORDER BY latest.running_balance DESC
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
                    latest.running_balance AS balance
                FROM public.financial_parties fp
                JOIN LATERAL (
                    SELECT ple.running_balance
                    FROM public.party_ledger_entries ple
                    JOIN public.party_subledger_accounts psa
                      ON psa.account_id = ple.account_id AND psa.role = 'ap'
                    WHERE ple.party_id = fp.id
                    ORDER BY ple.occurred_at DESC, ple.created_at DESC, ple.id DESC
                    LIMIT 1
                ) latest ON true
                WHERE fp.is_active
                  AND latest.running_balance > 0.01
                ORDER BY latest.running_balance DESC
                LIMIT 10
            ) sub
        )
    )
    INTO v_parties
    FROM public.financial_parties
    WHERE is_active;

    -- 4. TRIAL BALANCE — FIXED: date filter now applied correctly via subquery
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
        LEFT JOIN (
            SELECT jl2.account_id, jl2.debit, jl2.credit
            FROM public.journal_lines jl2
            JOIN public.journal_entries je2 ON je2.id = jl2.journal_entry_id
            WHERE je2.entry_date >= v_start AND je2.entry_date <= v_end
        ) jl ON jl.account_id = coa.id
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
