import React, { useState, useEffect, useMemo } from 'react';
import { getBaseCurrencyCode, getSupabaseClient } from '../../supabase';
import { Expense, CostCenter } from '../../types';
import { useToast } from '../../contexts/ToastContext';
import { useAuth } from '../../contexts/AuthContext';
import { localizeSupabaseError } from '../../utils/errorUtils';
// import { useSettings } from '../../contexts/SettingsContext';
import NumberInput from '../../components/NumberInput';
import CurrencyDualAmount from '../../components/common/CurrencyDualAmount';
import { nextMonthStartYmd, toDateInputValue, toDateTimeLocalInputValue, toMonthInputValue, toUtcIsoAtMiddayFromYmd } from '../../utils/dateUtils';

const ManageExpensesScreen: React.FC = () => {
    const { showNotification } = useToast();
    const { hasPermission } = useAuth();
    const [expenses, setExpenses] = useState<Expense[]>([]);
    const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
    const [loading, setLoading] = useState(true);
    const [baseCode, setBaseCode] = useState('—');
    const [currencyCodes, setCurrencyCodes] = useState<string[]>(['YER']);
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [isPaymentModalOpen, setIsPaymentModalOpen] = useState(false);
    const [filterDate, setFilterDate] = useState<string>(toMonthInputValue());
    const [paymentExpense, setPaymentExpense] = useState<Expense | null>(null);
    const [paymentAmount, setPaymentAmount] = useState<number>(0);
    const [paymentMethod, setPaymentMethod] = useState<string>('cash');
    const [paymentOccurredAt, setPaymentOccurredAt] = useState<string>(toDateTimeLocalInputValue());
    const [paymentAdvancedAccounting, setPaymentAdvancedAccounting] = useState(false);
    const [paymentOverrideAccountId, setPaymentOverrideAccountId] = useState<string>('');

    // Form State
    const [formData, setFormData] = useState<Partial<Expense>>({
        title: '',
        amount: 0,
        currency: '',
        fx_rate: 1,
        category: 'other',
        date: toDateInputValue(),
        notes: '',
        cost_center_id: ''
    });
    const [payNow, setPayNow] = useState(true);
    const [formPaymentMethod, setFormPaymentMethod] = useState<string>('cash');
    const [formAdvancedAccounting, setFormAdvancedAccounting] = useState(false);
    const [formOverrideAccountId, setFormOverrideAccountId] = useState<string>('');

    const [accounts, setAccounts] = useState<Array<{ id: string; code: string; name: string; account_type?: string }>>([]);
    const [accountsError, setAccountsError] = useState<string>('');

    const canViewAccounting = hasPermission('accounting.view') || hasPermission('accounting.manage');
    const canManageAccounting = hasPermission('accounting.manage');

    const normalizeCurrencyCode = (value: string) => {
        const code = String(value || '').trim().toUpperCase();
        return code === '—' ? '' : code;
    };

    const normalizePaymentMethod = (value: string) => {
        const raw = (value || '').trim();
        if (!raw) return 'cash';
        if (raw === 'card') return 'network';
        if (raw === 'bank') return 'kuraimi';
        return raw;
    };

    const isUuidText = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(v || '').trim());

    const buildDataWithOverride = (current: any, override: string | null) => {
        const base = current && typeof current === 'object' && !Array.isArray(current) ? { ...current } : {};
        if (!override) {
            if (Object.prototype.hasOwnProperty.call(base, 'overrideAccountId')) {
                delete (base as any).overrideAccountId;
            }
            return base;
        }
        return { ...base, overrideAccountId: override };
    };

    useEffect(() => {
        void getBaseCurrencyCode().then((c) => {
            if (!c) return;
            setBaseCode(c);
        });
    }, []);

    useEffect(() => {
        const run = async () => {
            const supabase = getSupabaseClient();
            if (!supabase) return;
            const base = normalizeCurrencyCode(baseCode) || 'YER';
            try {
                const { data, error } = await supabase.from('currencies').select('code').order('code', { ascending: true });
                if (error) throw error;
                const codes = (Array.isArray(data) ? data : [])
                    .map((r: any) => normalizeCurrencyCode(r?.code))
                    .filter(Boolean);
                const unique = Array.from(new Set(codes));
                if (unique.length > 0) {
                    setCurrencyCodes(unique);
                    return;
                }
                if (base) setCurrencyCodes([base]);
            } catch {
                if (base) setCurrencyCodes([base]);
            }
        };
        if (normalizeCurrencyCode(baseCode)) {
            void run();
        }
    }, [baseCode]);

    useEffect(() => {
        if (!isModalOpen) return;
        const base = normalizeCurrencyCode(baseCode) || 'YER';
        if (!base) return;
        setFormData((prev) => {
            const current = normalizeCurrencyCode(String((prev as any)?.currency || ''));
            const currency = current || base;
            const fxRate = currency === base ? 1 : Number((prev as any)?.fx_rate ?? 0) || 0;
            return { ...prev, currency, fx_rate: fxRate || (currency === base ? 1 : prev.fx_rate) };
        });
    }, [isModalOpen, baseCode]);

    useEffect(() => {
        if (!canViewAccounting) return;
        const run = async () => {
            const supabase = getSupabaseClient();
            if (!supabase) return;
            setAccountsError('');
            try {
                const { data, error } = await supabase
                    .from('chart_of_accounts')
                    .select('id,code,name,account_type,is_active')
                    .eq('is_active', true)
                    .order('code', { ascending: true });
                if (error) {
                    const { data: rpcData, error: rpcError } = await supabase.rpc('list_active_accounts');
                    if (rpcError) throw rpcError;
                    const list = Array.isArray(rpcData) ? rpcData : [];
                    setAccounts(list.map((r: any) => ({
                        id: String(r?.id || ''),
                        code: String(r?.code || ''),
                        name: String(r?.name || ''),
                        account_type: typeof r?.account_type === 'string' ? r.account_type : undefined,
                    })).filter((r: any) => Boolean(r.id)));
                    return;
                }
                const list = Array.isArray(data) ? data : [];
                setAccounts(list.map((r: any) => ({
                    id: String(r?.id || ''),
                    code: String(r?.code || ''),
                    name: String(r?.name || ''),
                    account_type: typeof r?.account_type === 'string' ? r.account_type : undefined,
                })).filter((r: any) => Boolean(r.id)));
            } catch (e) {
                setAccounts([]);
                setAccountsError(localizeSupabaseError(e));
            }
        };
        void run();
    }, [canViewAccounting]);

    useEffect(() => {
        fetchExpenses();
        fetchCostCenters();
    }, [filterDate]);

    const fetchFxRate = async (currency: string, dateYmd: string) => {
        const supabase = getSupabaseClient();
        if (!supabase) return null;
        const code = normalizeCurrencyCode(currency);
        if (!code) return null;
        const { data, error } = await supabase.rpc('get_fx_rate', {
            p_currency: code,
            p_date: dateYmd,
            p_rate_type: 'operational',
        });
        if (error) return null;
        const n = Number(data);
        return Number.isFinite(n) && n > 0 ? n : null;
    };

    const fetchCostCenters = async () => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        const { data } = await supabase.from('cost_centers').select('*').eq('is_active', true).order('name');
        setCostCenters(data || []);
    };

    const fetchExpenses = async () => {
        setLoading(true);
        try {
            const supabase = getSupabaseClient();
            if (!supabase) return;

            // Filter by selected month
            const startOfMonth = `${filterDate}-01`;
            const endOfMonth = nextMonthStartYmd(filterDate);

            const { data, error } = await supabase
                .from('expenses')
                .select('*')
                .gte('date', startOfMonth)
                .lt('date', endOfMonth)
                .order('date', { ascending: false });

            if (error) throw error;
            setExpenses(data || []);
        } catch (error) {
            console.error('Error fetching expenses:', error);
            showNotification('فشل تحميل المصاريف', 'error');
        } finally {
            setLoading(false);
        }
    };

    const handleSubmit = async (e: React.FormEvent) => {
        e.preventDefault();
        try {
            const supabase = getSupabaseClient();
            if (!supabase) return;

            if (!formData.title || !formData.amount || !formData.date || !formData.category) {
                showNotification('يرجى ملء جميع الحقول المطلوبة', 'error');
                return;
            }

            const base = normalizeCurrencyCode(baseCode) || 'YER';
            const selectedCurrency = normalizeCurrencyCode(String((formData as any)?.currency || base));
            if (!selectedCurrency) {
                showNotification('يرجى اختيار العملة', 'error');
                return;
            }

            let fxRate = Number((formData as any)?.fx_rate ?? 0);
            if (selectedCurrency === base) {
                fxRate = 1;
            } else if (!Number.isFinite(fxRate) || fxRate <= 0) {
                const lookedUp = await fetchFxRate(selectedCurrency, String(formData.date));
                if (!lookedUp) {
                    showNotification('لا يوجد سعر صرف لهذه العملة في هذا التاريخ', 'error');
                    return;
                }
                fxRate = lookedUp;
            }

            const { data: inserted, error } = await supabase.from('expenses').insert({
                title: formData.title,
                amount: formData.amount,
                currency: selectedCurrency,
                fx_rate: fxRate,
                category: formData.category,
                date: formData.date,
                notes: formData.notes,
                cost_center_id: formData.cost_center_id || null,
                data: formAdvancedAccounting && canManageAccounting && isUuidText(formOverrideAccountId)
                    ? buildDataWithOverride({}, formOverrideAccountId.trim())
                    : {},
            }).select('*').single();

            if (error) throw error;

            if (inserted?.id) {
                const occurredAt = toUtcIsoAtMiddayFromYmd(formData.date);
                if (payNow) {
                    const { error: payError } = await supabase.rpc('record_expense_payment', {
                        p_expense_id: inserted.id,
                        p_amount: Number(formData.amount),
                        p_method: normalizePaymentMethod(formPaymentMethod),
                        p_occurred_at: occurredAt,
                    });
                    if (payError) throw payError;
                } else {
                    const { error: accrualError } = await supabase.rpc('record_expense_accrual', {
                        p_expense_id: inserted.id,
                        p_amount: Number(formData.amount),
                        p_occurred_at: occurredAt,
                    });
                    if (accrualError) throw accrualError;
                }
            }

            showNotification('تم إضافة المصروف بنجاح', 'success');
            setIsModalOpen(false);
            setFormData({
                title: '',
                amount: 0,
                currency: '',
                fx_rate: 1,
                category: 'other',
                date: toDateInputValue(),
                notes: '',
                cost_center_id: ''
            });
            setPayNow(true);
            setFormPaymentMethod('cash');
            setFormAdvancedAccounting(false);
            setFormOverrideAccountId('');
            fetchExpenses();
        } catch (error) {
            console.error('Error adding expense:', error);
            showNotification('فشل إضافة المصروف', 'error');
        }
    };

    const openPaymentModal = (exp: Expense) => {
        const d = (exp as any)?.data || {};
        const existingOverride = typeof d?.overrideAccountId === 'string' ? d.overrideAccountId : '';
        setPaymentExpense(exp);
        setPaymentAmount(exp.amount);
        setPaymentMethod('cash');
        setPaymentOccurredAt(toDateTimeLocalInputValue());
        setPaymentOverrideAccountId(existingOverride);
        setPaymentAdvancedAccounting(canViewAccounting && Boolean(String(existingOverride || '').trim()));
        setIsPaymentModalOpen(true);
    };

    const handleRecordPayment = async (e: React.FormEvent) => {
        e.preventDefault();
        if (!paymentExpense) return;
        try {
            const supabase = getSupabaseClient();
            if (!supabase) return;
            const occurredAt = paymentOccurredAt ? new Date(paymentOccurredAt).toISOString() : new Date().toISOString();
            if (paymentAdvancedAccounting && canManageAccounting) {
                const override = isUuidText(paymentOverrideAccountId) ? paymentOverrideAccountId.trim() : '';
                const current = (paymentExpense as any)?.data || {};
                const next = buildDataWithOverride(current, override || null);
                const { error: upErr } = await supabase.from('expenses').update({ data: next }).eq('id', paymentExpense.id);
                if (upErr) throw upErr;
            }
            const { error } = await supabase.rpc('record_expense_payment', {
                p_expense_id: paymentExpense.id,
                p_amount: Number(paymentAmount),
                p_method: normalizePaymentMethod(paymentMethod),
                p_occurred_at: occurredAt,
            });
            if (error) throw error;
            showNotification('تم تسجيل الدفع بنجاح', 'success');
            setIsPaymentModalOpen(false);
            setPaymentExpense(null);
            setPaymentAdvancedAccounting(false);
            setPaymentOverrideAccountId('');
            fetchExpenses();
        } catch (error) {
            console.error('Error recording expense payment:', error);
            showNotification('فشل تسجيل الدفع', 'error');
        }
    };

    const handleDelete = async (id: string) => {
        if (!window.confirm('هل أنت متأكد من حذف هذا المصروف؟')) return;
        try {
            const supabase = getSupabaseClient();
            if (!supabase) return;
            const { error } = await supabase.from('expenses').delete().eq('id', id);
            if (error) throw error;
            showNotification('تم حذف المصروف', 'success');
            fetchExpenses();
        } catch (error: any) {
            const msg = error?.message ? `فشل حذف المصروف: ${error.message}` : 'فشل حذف المصروف';
            showNotification(msg, 'error');
        }
    };

    const totalExpensesBase = useMemo(() => {
        const base = normalizeCurrencyCode(baseCode) || 'YER';
        return expenses.reduce((sum, exp) => {
            const anyExp = exp as any;
            const expCurrency = normalizeCurrencyCode(String(anyExp?.currency || base));
            const fx = Number(anyExp?.fx_rate ?? 1);
            const baseAmount = typeof anyExp?.base_amount === 'number' ? Number(anyExp.base_amount) : Number(anyExp?.amount || 0) * (Number.isFinite(fx) && fx > 0 ? fx : 1);
            if (expCurrency && base && expCurrency !== base) return sum + (Number.isFinite(baseAmount) ? baseAmount : 0);
            return sum + Number(anyExp?.amount || 0);
        }, 0);
    }, [expenses, baseCode]);

    const categoryLabels: Record<string, string> = {
        rent: 'إيجار',
        salary: 'رواتب',
        utilities: 'كهرباء/ماء/خدمات',
        marketing: 'تسويق',
        maintenance: 'صيانة',
        other: 'أخرى'
    };

    return (
        <div className="animate-fade-in p-4">
            <div className="flex justify-between items-center mb-6">
                <h1 className="text-3xl font-bold dark:text-white">إدارة المصاريف</h1>
                <button
                    onClick={() => setIsModalOpen(true)}
                    className="bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded-lg flex items-center gap-2"
                >
                    <span>+ تسجيل مصروف</span>
                </button>
            </div>

            {/* Filter */}
            <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow mb-6 flex items-center gap-4">
                <label className="text-gray-700 dark:text-gray-300">الشهر:</label>
                <input
                    type="month"
                    value={filterDate}
                    onChange={(e) => setFilterDate(e.target.value)}
                    className="p-2 border rounded-md dark:bg-gray-700 dark:border-gray-600"
                />
                <div className="mr-auto font-bold text-lg dark:text-white">
                    الإجمالي: <span className="text-red-500" dir="ltr">{Number(totalExpensesBase || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} {normalizeCurrencyCode(baseCode) || '—'}</span>
                </div>
            </div>

            {/* List */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow">
                <div className="overflow-x-auto">
                    <table className="min-w-[700px] w-full text-right">
                        <thead className="bg-gray-50 dark:bg-gray-700">
                        <tr>
                            <th className="p-2 sm:p-3 text-xs sm:text-sm text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">التاريخ</th>
                            <th className="p-2 sm:p-3 text-xs sm:text-sm text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">العنوان</th>
                            <th className="p-2 sm:p-3 text-xs sm:text-sm text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الفئة</th>
                            <th className="p-2 sm:p-3 text-xs sm:text-sm text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">المبلغ</th>
                            <th className="p-2 sm:p-3 text-xs sm:text-sm text-gray-600 dark:text-gray-300">الإجراءات</th>
                        </tr>
                        </thead>
                        <tbody className="divide-y divide-gray-200 dark:divide-gray-700">
                        {loading ? (
                            <tr><td colSpan={5} className="p-4 text-center">جاري التحميل...</td></tr>
                        ) : expenses.length === 0 ? (
                            <tr><td colSpan={5} className="p-4 text-center text-gray-500">لا توجد مصاريف لهذا الشهر.</td></tr>
                        ) : (
                            expenses.map(exp => (
                                <tr key={exp.id} className="hover:bg-gray-50 dark:hover:bg-gray-750">
                                    <td className="p-2 sm:p-3 text-xs sm:text-sm dark:text-gray-300 border-r dark:border-gray-700" dir="ltr">{exp.date}</td>
                                    <td className="p-2 sm:p-3 text-xs sm:text-sm dark:text-gray-300 font-medium border-r dark:border-gray-700">
                                        {exp.title}
                                        {exp.notes && <div className="text-xs text-gray-500">{exp.notes}</div>}
                                    </td>
                                    <td className="p-2 sm:p-3 border-r dark:border-gray-700"><span className="px-2 py-1 bg-gray-100 dark:bg-gray-700 rounded text-xs">{categoryLabels[exp.category] || exp.category}</span></td>
                                    <td className="p-2 sm:p-3 font-bold text-red-600 border-r dark:border-gray-700">
                                        <CurrencyDualAmount
                                            amount={Number((exp as any)?.amount || 0)}
                                            currencyCode={normalizeCurrencyCode(String((exp as any)?.currency || normalizeCurrencyCode(baseCode))) || 'YER'}
                                            baseAmount={(normalizeCurrencyCode(String((exp as any)?.currency || normalizeCurrencyCode(baseCode))) || 'YER') !== (normalizeCurrencyCode(baseCode) || 'YER')
                                                ? (typeof (exp as any)?.base_amount === 'number'
                                                    ? Number((exp as any).base_amount)
                                                    : Number((exp as any)?.amount || 0) * Number((exp as any)?.fx_rate || 1))
                                                : undefined}
                                            fxRate={(normalizeCurrencyCode(String((exp as any)?.currency || normalizeCurrencyCode(baseCode))) || 'YER') !== (normalizeCurrencyCode(baseCode) || 'YER')
                                                ? Number((exp as any)?.fx_rate || 1)
                                                : undefined}
                                            baseCurrencyCode={normalizeCurrencyCode(baseCode) || 'YER'}
                                        />
                                    </td>
                                    <td className="p-2 sm:p-3">
                                        <button onClick={() => openPaymentModal(exp)} className="text-primary-600 hover:text-primary-700 text_sm ml-3">دفع</button>
                                        <button onClick={() => handleDelete(exp.id)} className="text-red-500 hover:text-red-700 text_sm">حذف</button>
                                    </td>
                                </tr>
                            ))
                        )}
                        </tbody>
                    </table>
                </div>
            </div>

            {/* Modal */}
            {isModalOpen && (
                <div className="fixed inset-0 bg-black bg-opacity-50 flex justify-center items-center z-50 p-4">
                    <div className="bg-white dark:bg-gray-800 rounded-lg shadow-xl w-full max-w-md p-6 animate-fade-in-up">
                        <h2 className="text-xl font-bold mb-4 dark:text-white">تسجيل مصروف جديد</h2>
                        <form onSubmit={handleSubmit} className="space-y-4">
                            <div>
                                <label className="block text-sm font-medium mb-1 dark:text-gray-300">عنوان المصروف</label>
                                <input
                                    type="text"
                                    required
                                    value={formData.title}
                                    onChange={e => setFormData({ ...formData, title: e.target.value })}
                                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                    placeholder="مثال: فاتورة كهرباء"
                                />
                            </div>
                            <div className="grid grid-cols-2 gap-4">
                                <div>
                                    <label className="block text-sm font-medium mb-1 dark:text-gray-300">المبلغ</label>
                                    <NumberInput
                                        id="amount"
                                        name="amount"
                                        value={formData.amount || 0}
                                        onChange={e => setFormData({ ...formData, amount: parseFloat(e.target.value) })}
                                        min={0}
                                        step={0.5}
                                    />
                                </div>
                                <div>
                                    <label className="block text-sm font-medium mb-1 dark:text-gray-300">العملة</label>
                                    <select
                                        value={normalizeCurrencyCode(String((formData as any)?.currency || normalizeCurrencyCode(baseCode))) || (currencyCodes[0] || normalizeCurrencyCode(baseCode) || 'YER')}
                                        onChange={async (e) => {
                                            const nextCurrency = normalizeCurrencyCode(e.target.value);
                                            const base = normalizeCurrencyCode(baseCode) || 'YER';
                                            if (!nextCurrency) return;
                                            if (nextCurrency === base) {
                                                setFormData({ ...formData, currency: nextCurrency, fx_rate: 1 });
                                                return;
                                            }
                                            setFormData({ ...formData, currency: nextCurrency });
                                            const lookedUp = await fetchFxRate(nextCurrency, String(formData.date));
                                            if (lookedUp) {
                                                setFormData((prev) => ({ ...prev, currency: nextCurrency, fx_rate: lookedUp }));
                                            }
                                        }}
                                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                    >
                                        {(currencyCodes.length > 0 ? currencyCodes : [normalizeCurrencyCode(baseCode) || 'YER']).map((c) => (
                                            <option key={c} value={c}>{c}</option>
                                        ))}
                                    </select>
                                </div>
                            </div>
                            <div className="grid grid-cols-2 gap-4">
                                <div>
                                    <label className="block text-sm font-medium mb-1 dark:text-gray-300">سعر الصرف (إلى {normalizeCurrencyCode(baseCode) || '—'})</label>
                                    <NumberInput
                                        id="fxRate"
                                        name="fxRate"
                                        value={Number((formData as any)?.fx_rate ?? 1)}
                                        onChange={e => setFormData({ ...formData, fx_rate: parseFloat(e.target.value) })}
                                        min={0}
                                        step={0.000001}
                                    />
                                </div>
                                <div>
                                    <label className="block text-sm font-medium mb-1 dark:text-gray-300">التاريخ</label>
                                    <input
                                        type="date"
                                        required
                                        value={formData.date}
                                        onChange={async (e) => {
                                            const nextDate = e.target.value;
                                            setFormData({ ...formData, date: nextDate });
                                            const base = normalizeCurrencyCode(baseCode) || 'YER';
                                            const cur = normalizeCurrencyCode(String((formData as any)?.currency || base));
                                            if (cur && base && cur !== base) {
                                                const lookedUp = await fetchFxRate(cur, nextDate);
                                                if (lookedUp) setFormData((prev) => ({ ...prev, fx_rate: lookedUp }));
                                            } else if (cur === base) {
                                                setFormData((prev) => ({ ...prev, fx_rate: 1 }));
                                            }
                                        }}
                                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                    />
                                </div>
                            </div>
                            <div>
                                <label className="block text-sm font-medium mb-1 dark:text-gray-300">الفئة</label>
                                <select
                                    value={formData.category}
                                    onChange={e => setFormData({ ...formData, category: e.target.value as any })}
                                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                >
                                    {Object.entries(categoryLabels).map(([key, label]) => (
                                        <option key={key} value={key}>{label}</option>
                                    ))}
                                </select>
                            </div>
                            <div>
                                <label className="block text-sm font-medium mb-1 dark:text-gray-300">مركز التكلفة (اختياري)</label>
                                <select
                                    value={formData.cost_center_id || ''}
                                    onChange={e => setFormData({ ...formData, cost_center_id: e.target.value })}
                                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                >
                                    <option value="">-- اختر مركز تكلفة --</option>
                                    {costCenters.map(cc => (
                                        <option key={cc.id} value={cc.id}>{cc.name}</option>
                                    ))}
                                </select>
                            </div>
                            <div>
                                <label className="block text-sm font-medium mb-1 dark:text-gray-300">ملاحظات</label>
                                <textarea
                                    value={formData.notes || ''}
                                    onChange={e => setFormData({ ...formData, notes: e.target.value })}
                                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                    rows={2}
                                />
                            </div>
                            <div className="grid grid-cols-2 gap-4">
                                <div className="flex items-center gap-2">
                                    <input
                                        id="payNow"
                                        type="checkbox"
                                        checked={payNow}
                                        onChange={e => setPayNow(e.target.checked)}
                                    />
                                    <label htmlFor="payNow" className="text-sm font-medium dark:text-gray-300">تم الدفع الآن</label>
                                </div>
                                <div>
                                    <label className="block text-sm font-medium mb-1 dark:text-gray-300">طريقة الدفع</label>
                                    <select
                                        value={formPaymentMethod}
                                        onChange={e => setFormPaymentMethod(e.target.value)}
                                        disabled={!payNow}
                                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 disabled:opacity-60"
                                    >
                                        <option value="cash">نقدًا</option>
                                        <option value="network">حوالات</option>
                                        <option value="kuraimi">حسابات بنكية</option>
                                    </select>
                                </div>
                            </div>
                            {canViewAccounting && (
                                <div className="space-y-2 rounded-lg border border-gray-200 dark:border-gray-600 p-3">
                                    <label className="flex items-center gap-2 text-sm font-medium dark:text-gray-300">
                                        <input
                                            type="checkbox"
                                            checked={formAdvancedAccounting}
                                            onChange={(e) => setFormAdvancedAccounting(e.target.checked)}
                                        />
                                        إعدادات محاسبية متقدمة
                                    </label>
                                    {formAdvancedAccounting && (
                                        <div>
                                            <label className="block text-sm font-medium mb-1 dark:text-gray-300">الحساب المحاسبي البديل (Advanced)</label>
                                            <select
                                                value={formOverrideAccountId}
                                                onChange={(e) => setFormOverrideAccountId(e.target.value)}
                                                disabled={!canManageAccounting}
                                                className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 disabled:opacity-60"
                                            >
                                                <option value="">-- بدون --</option>
                                                {accounts.map(a => (
                                                    <option key={a.id} value={a.id}>{a.code} — {a.name}</option>
                                                ))}
                                            </select>
                                            {accountsError && (
                                                <div className="mt-1 text-xs text-red-600">{accountsError}</div>
                                            )}
                                        </div>
                                    )}
                                </div>
                            )}
                            <div className="flex justify-end gap-2 pt-4">
                                <button type="button" onClick={() => setIsModalOpen(false)} className="px-4 py-2 bg-gray-200 rounded hover:bg-gray-300 text-gray-800">إلغاء</button>
                                <button type="submit" className="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700">حفظ</button>
                            </div>
                        </form>
                    </div>
                </div>
            )}

            {isPaymentModalOpen && paymentExpense && (
                <div className="fixed inset-0 bg-black bg-opacity-50 flex justify-center items-center z-50 p-4">
                    <div className="bg-white dark:bg-gray-800 rounded-lg shadow-xl w-full max-w-md p-6 animate-fade-in-up">
                        <h2 className="text-xl font-bold mb-4 dark:text-white">تسجيل دفع للمصروف</h2>
                        <form onSubmit={handleRecordPayment} className="space-y-4">
                            <div className="text-sm dark:text-gray-300">
                                {paymentExpense.title} ({paymentExpense.date})
                            </div>
                            <div className="rounded-lg border border-gray-200 dark:border-gray-700 p-3">
                                <CurrencyDualAmount
                                    amount={Number((paymentExpense as any)?.amount || 0)}
                                    currencyCode={normalizeCurrencyCode(String((paymentExpense as any)?.currency || normalizeCurrencyCode(baseCode))) || 'YER'}
                                    baseAmount={(normalizeCurrencyCode(String((paymentExpense as any)?.currency || normalizeCurrencyCode(baseCode))) || 'YER') !== (normalizeCurrencyCode(baseCode) || 'YER')
                                        ? (typeof (paymentExpense as any)?.base_amount === 'number'
                                            ? Number((paymentExpense as any).base_amount)
                                            : Number((paymentExpense as any)?.amount || 0) * Number((paymentExpense as any)?.fx_rate || 1))
                                        : undefined}
                                    fxRate={(normalizeCurrencyCode(String((paymentExpense as any)?.currency || normalizeCurrencyCode(baseCode))) || 'YER') !== (normalizeCurrencyCode(baseCode) || 'YER')
                                        ? Number((paymentExpense as any)?.fx_rate || 1)
                                        : undefined}
                                    baseCurrencyCode={normalizeCurrencyCode(baseCode) || 'YER'}
                                />
                            </div>
                            <div className="grid grid-cols-2 gap-4">
                                <div>
                                    <label className="block text-sm font-medium mb-1 dark:text-gray-300">المبلغ</label>
                                    <NumberInput
                                        id="paymentAmount"
                                        name="paymentAmount"
                                        value={paymentAmount}
                                        onChange={e => setPaymentAmount(parseFloat(e.target.value))}
                                        min={0}
                                        step={0.5}
                                    />
                                </div>
                                <div>
                                    <label className="block text-sm font-medium mb-1 dark:text-gray-300">طريقة الدفع</label>
                                    <select
                                        value={paymentMethod}
                                        onChange={e => setPaymentMethod(e.target.value)}
                                        className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                    >
                                        <option value="cash">نقدًا</option>
                                        <option value="network">حوالات</option>
                                        <option value="kuraimi">حسابات بنكية</option>
                                    </select>
                                </div>
                            </div>
                            <div>
                                <label className="block text-sm font-medium mb-1 dark:text-gray-300">وقت الدفع</label>
                                <input
                                    type="datetime-local"
                                    value={paymentOccurredAt}
                                    onChange={e => setPaymentOccurredAt(e.target.value)}
                                    className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600"
                                />
                            </div>
                            {canViewAccounting && (
                                <div className="space-y-2 rounded-lg border border-gray-200 dark:border-gray-600 p-3">
                                    <label className="flex items-center gap-2 text-sm font-medium dark:text-gray-300">
                                        <input
                                            type="checkbox"
                                            checked={paymentAdvancedAccounting}
                                            onChange={(e) => setPaymentAdvancedAccounting(e.target.checked)}
                                        />
                                        إعدادات محاسبية متقدمة
                                    </label>
                                    {paymentAdvancedAccounting && (
                                        <div>
                                            <label className="block text-sm font-medium mb-1 dark:text-gray-300">الحساب المحاسبي البديل (Advanced)</label>
                                            <select
                                                value={paymentOverrideAccountId}
                                                onChange={(e) => setPaymentOverrideAccountId(e.target.value)}
                                                disabled={!canManageAccounting}
                                                className="w-full p-2 border rounded dark:bg-gray-700 dark:border-gray-600 disabled:opacity-60"
                                            >
                                                <option value="">-- بدون --</option>
                                                {accounts.map(a => (
                                                    <option key={a.id} value={a.id}>{a.code} — {a.name}</option>
                                                ))}
                                            </select>
                                            {accountsError && (
                                                <div className="mt-1 text-xs text-red-600">{accountsError}</div>
                                            )}
                                        </div>
                                    )}
                                </div>
                            )}
                            <div className="flex justify-end gap-2 pt-4">
                                <button
                                    type="button"
                                    onClick={() => { setIsPaymentModalOpen(false); setPaymentExpense(null); }}
                                    className="px-4 py-2 bg-gray-200 rounded hover:bg-gray-300 text-gray-800"
                                >
                                    إلغاء
                                </button>
                                <button type="submit" className="px-4 py-2 bg-primary-600 text-white rounded hover:bg-primary-700">تسجيل الدفع</button>
                            </div>
                        </form>
                    </div>
                </div>
            )}
        </div>
    );
};

export default ManageExpensesScreen;
