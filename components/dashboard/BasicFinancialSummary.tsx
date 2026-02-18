import React, { useEffect, useState } from 'react';
import { getSupabaseClient } from '../../supabase';
import { useAuth } from '../../contexts/AuthContext';
import * as Icons from '../icons';

type FinancialSummary = {
    cashAvailable: number; // Cash + Bank
    receivables: number;   // AR
    payables: number;      // AP
    net: number;           // (Cash + AR) - AP
    currency: string;
};

const BasicFinancialSummary: React.FC = () => {
    const { hasPermission } = useAuth();
    const [summary, setSummary] = useState<FinancialSummary | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    // Permission check: Only show if user has 'accounting.view'
    const canViewFinancials = hasPermission('accounting.view');

    useEffect(() => {
        if (!canViewFinancials) {
            setLoading(false);
            return;
        }

        const fetchFinancials = async () => {
            setLoading(true);
            setError(null);
            try {
                const supabase = getSupabaseClient();
                if (!supabase) throw new Error('Supabase client not initialized');

                // 1. Get Cash & Bank Balances from Trial Balance (RPC)
                // We use trial_balance_by_range(null, null) which returns current balances
                const { data: trialRows, error: trialError } = await supabase.rpc('trial_balance', {
                    p_start: null,
                    p_end: null
                });

                if (trialError) throw trialError;

                // Sum 1010 (Cash) and 1020 (Bank)
                // Note: Check exact codes in your Chart of Accounts. 
                // Based on migration `seed_default_accounting_accounts.sql`: cash='1010', bank='1020'.
                // trial_balance returns: account_code, balance
                const cashRows = (trialRows || []).filter((r: any) =>
                    r.account_code === '1010' || r.account_code === '1020'
                );
                const cashTotal = cashRows.reduce((sum: number, r: any) => sum + (Number(r.balance) || 0), 0);

                // 2. Get Total Receivables (AR) from Party Aging View
                const { data: arData, error: arError } = await supabase
                    .from('party_ar_aging_summary')
                    .select('total_outstanding');

                if (arError) throw arError;
                const arTotal = (arData || []).reduce((sum: number, r: any) => sum + (Number(r.total_outstanding) || 0), 0);

                // 3. Get Total Payables (AP) from Party Aging View
                const { data: apData, error: apError } = await supabase
                    .from('party_ap_aging_summary')
                    .select('total_outstanding');

                if (apError) throw apError;
                const apTotal = (apData || []).reduce((sum: number, r: any) => sum + (Number(r.total_outstanding) || 0), 0);

                setSummary({
                    cashAvailable: cashTotal,
                    receivables: arTotal,
                    payables: apTotal,
                    net: (cashTotal + arTotal) - apTotal,
                    currency: 'ر.ي' // Default or fetch from settings if needed
                });

            } catch (err: any) {
                console.error('Error fetching financial summary:', err);
                setError('تعذر تحميل البيانات المالية');
            } finally {
                setLoading(false);
            }
        };

        fetchFinancials();
    }, [canViewFinancials]);

    if (!canViewFinancials) return null;

    if (loading) {
        return (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
                {[...Array(4)].map((_, i) => (
                    <div key={i} className="h-32 bg-gray-100 dark:bg-gray-800 rounded-xl animate-pulse" />
                ))}
            </div>
        );
    }

    if (error) {
        return (
            <div className="mb-6 p-4 bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400 rounded-lg text-sm">
                {error}
            </div>
        );
    }

    if (!summary) return null;

    const cards = [
        {
            title: 'السيولة المتوفرة',
            subtitle: 'نقدية + بنك',
            value: summary.cashAvailable,
            icon: Icons.DollarSign,
            colorClass: 'text-emerald-600 dark:text-emerald-400',
            bgClass: 'bg-emerald-50 dark:bg-emerald-900/20',
            approximated: false
        },
        {
            title: 'لي عند الناس',
            subtitle: 'إجمالي الديون (لكم)',
            value: summary.receivables,
            icon: Icons.ReportIcon,
            colorClass: 'text-blue-600 dark:text-blue-400',
            bgClass: 'bg-blue-50 dark:bg-blue-900/20',
            approximated: false
        },
        {
            title: 'علي للناس',
            subtitle: 'إجمالي الديون (عليكم)',
            value: summary.payables,
            icon: Icons.CreditCardIcon,
            colorClass: 'text-rose-600 dark:text-rose-400',
            bgClass: 'bg-rose-50 dark:bg-rose-900/20',
            approximated: false
        },
        {
            title: 'الوضع المالي التقريبي',
            subtitle: '(سيولة + لي) - (علي)',
            value: summary.net,
            icon: Icons.TagIcon,
            colorClass: 'text-gray-700 dark:text-gray-300',
            bgClass: 'bg-gray-100 dark:bg-gray-700/50',
            approximated: true // Highlight that this is an estimation
        }
    ];

    return (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
            {cards.map((card, idx) => (
                <div key={idx} className="bg-white dark:bg-gray-800 rounded-xl shadow-sm border border-gray-100 dark:border-gray-700 p-6 flex flex-col justify-between hover:shadow-md transition-shadow">
                    <div className="flex justify-between items-start mb-4">
                        <div>
                            <h3 className="text-sm font-semibold text-gray-500 dark:text-gray-400 mb-1">{card.title}</h3>
                            <p className="text-xs text-gray-400 dark:text-gray-500">{card.subtitle}</p>
                        </div>
                        <div className={`p-2 rounded-lg ${card.bgClass}`}>
                            {card.icon && <card.icon className={`w-5 h-5 ${card.colorClass}`} />}
                        </div>
                    </div>
                    <div>
                        <div className={`text-2xl font-bold font-mono tracking-tight ${card.colorClass}`} dir="ltr">
                            {card.value.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                            <span className="text-sm font-normal text-gray-400 ml-1">{summary.currency}</span>
                        </div>
                    </div>
                </div>
            ))}
        </div>
    );
};

export default BasicFinancialSummary;
