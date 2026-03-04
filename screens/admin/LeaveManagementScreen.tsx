import { useCallback, useEffect, useState } from 'react';
import { getSupabaseClient } from '../../supabase';
import PageLoader from '../../components/PageLoader';
import { useToast } from '../../contexts/ToastContext';

type Employee = { id: string; full_name: string; employee_code?: string | null; is_active: boolean };
type LeaveType = { id: string; code: string; name: string; is_paid: boolean; default_days_per_year: number; is_active: boolean };
type LeaveRequest = {
    id: string;
    employee_id: string;
    leave_type_id: string;
    start_date: string;
    end_date: string;
    total_days: number;
    status: string;
    notes?: string | null;
    created_at: string;
    employee_name?: string;
    leave_type_name?: string;
};
type LeaveBalance = {
    id: string;
    employee_id: string;
    leave_type_id: string;
    year: number;
    accrued_days: number;
    taken_days: number;
    balance_days: number;
    employee_name?: string;
    leave_type_name?: string;
};

export default function LeaveManagementScreen() {
    const { showNotification } = useToast();
    const supabase = getSupabaseClient();
    const [loading, setLoading] = useState(true);
    const [tab, setTab] = useState<'requests' | 'balances' | 'types'>('requests');
    const [employees, setEmployees] = useState<Employee[]>([]);
    const [leaveTypes, setLeaveTypes] = useState<LeaveType[]>([]);
    const [requests, setRequests] = useState<LeaveRequest[]>([]);
    const [balances, setBalances] = useState<LeaveBalance[]>([]);

    // Drafts
    const [reqDraft, setReqDraft] = useState({
        employee_id: '', leave_type_id: '', start_date: '', end_date: '', total_days: 0, notes: '',
    });
    const [typeDraft, setTypeDraft] = useState({
        code: '', name: '', is_paid: true, default_days_per_year: 30, is_active: true,
    });
    const [balDraft, setBalDraft] = useState({
        employee_id: '', leave_type_id: '', year: new Date().getFullYear(), accrued_days: 30,
    });

    const loadAll = useCallback(async () => {
        if (!supabase) return;
        const [e, lt, lr, lb] = await Promise.all([
            supabase.from('payroll_employees').select('id,full_name,employee_code,is_active').order('full_name'),
            supabase.from('hr_leave_types').select('*').order('code'),
            supabase.from('hr_leave_requests').select('*,payroll_employees(full_name),hr_leave_types(name)').order('created_at', { ascending: false }).limit(100),
            supabase.from('hr_leave_balances').select('*,payroll_employees(full_name),hr_leave_types(name)').order('year', { ascending: false }),
        ]);
        if (e.error) throw e.error;
        if (lt.error) throw lt.error;
        if (lr.error) throw lr.error;
        if (lb.error) throw lb.error;

        setEmployees((Array.isArray(e.data) ? e.data : []).map((x: any) => ({
            id: String(x.id), full_name: String(x.full_name || ''), employee_code: x.employee_code ? String(x.employee_code) : null, is_active: Boolean(x.is_active),
        })));
        setLeaveTypes((Array.isArray(lt.data) ? lt.data : []).map((x: any) => ({
            id: String(x.id), code: String(x.code || ''), name: String(x.name || ''), is_paid: Boolean(x.is_paid), default_days_per_year: Number(x.default_days_per_year || 0), is_active: Boolean(x.is_active),
        })));
        setRequests((Array.isArray(lr.data) ? lr.data : []).map((x: any) => ({
            id: String(x.id), employee_id: String(x.employee_id), leave_type_id: String(x.leave_type_id),
            start_date: String(x.start_date || ''), end_date: String(x.end_date || ''), total_days: Number(x.total_days || 0),
            status: String(x.status || 'draft'), notes: x.notes ? String(x.notes) : null, created_at: String(x.created_at || ''),
            employee_name: String(x?.payroll_employees?.full_name || ''), leave_type_name: String(x?.hr_leave_types?.name || ''),
        })));
        setBalances((Array.isArray(lb.data) ? lb.data : []).map((x: any) => ({
            id: String(x.id), employee_id: String(x.employee_id), leave_type_id: String(x.leave_type_id),
            year: Number(x.year || 0), accrued_days: Number(x.accrued_days || 0), taken_days: Number(x.taken_days || 0), balance_days: Number(x.balance_days || 0),
            employee_name: String(x?.payroll_employees?.full_name || ''), leave_type_name: String(x?.hr_leave_types?.name || ''),
        })));
    }, [supabase]);

    useEffect(() => {
        (async () => {
            setLoading(true);
            try { await loadAll(); } catch (e: any) { showNotification(String(e?.message || 'تعذر التحميل'), 'error'); }
            finally { setLoading(false); }
        })();
    }, [loadAll, showNotification]);

    // Calculate total_days automatically
    useEffect(() => {
        if (reqDraft.start_date && reqDraft.end_date) {
            const s = new Date(reqDraft.start_date);
            const e = new Date(reqDraft.end_date);
            const diff = Math.max(0, Math.ceil((e.getTime() - s.getTime()) / (1000 * 60 * 60 * 24)) + 1);
            setReqDraft(prev => ({ ...prev, total_days: diff }));
        }
    }, [reqDraft.start_date, reqDraft.end_date]);

    const addRequest = async () => {
        if (!supabase) return;
        if (!reqDraft.employee_id || !reqDraft.leave_type_id || !reqDraft.start_date || !reqDraft.end_date) {
            showNotification('يرجى ملء جميع الحقول', 'error'); return;
        }
        try {
            const { error } = await supabase.from('hr_leave_requests').insert({
                employee_id: reqDraft.employee_id, leave_type_id: reqDraft.leave_type_id,
                start_date: reqDraft.start_date, end_date: reqDraft.end_date, total_days: reqDraft.total_days,
                notes: reqDraft.notes.trim() || null,
            });
            if (error) throw error;
            showNotification('تم إنشاء طلب الإجازة بنجاح', 'success');
            setReqDraft({ employee_id: '', leave_type_id: '', start_date: '', end_date: '', total_days: 0, notes: '' });
            await loadAll();
        } catch (e: any) { showNotification(String(e?.message || 'تعذر الإنشاء'), 'error'); }
    };

    const updateRequestStatus = async (id: string, status: string) => {
        if (!supabase) return;
        try {
            const payload: Record<string, any> = { status };
            if (status === 'approved') {
                payload.approved_at = new Date().toISOString();
            }
            const { error } = await supabase.from('hr_leave_requests').update(payload).eq('id', id);
            if (error) throw error;

            // If approved, update balance taken_days
            if (status === 'approved') {
                const req = requests.find(r => r.id === id);
                if (req) {
                    const year = new Date(req.start_date).getFullYear();
                    // Upsert the balance
                    const { data: existingBal } = await supabase
                        .from('hr_leave_balances')
                        .select('id,taken_days')
                        .eq('employee_id', req.employee_id)
                        .eq('leave_type_id', req.leave_type_id)
                        .eq('year', year)
                        .maybeSingle();
                    if (existingBal) {
                        await supabase.from('hr_leave_balances').update({
                            taken_days: Number((existingBal as any).taken_days || 0) + req.total_days,
                            last_updated_at: new Date().toISOString(),
                        }).eq('id', (existingBal as any).id);
                    }
                }
            }

            showNotification(`تم تحديث حالة الطلب إلى ${status === 'approved' ? 'موافق عليه' : status === 'rejected' ? 'مرفوض' : status}`, 'success');
            await loadAll();
        } catch (e: any) { showNotification(String(e?.message || 'تعذر التحديث'), 'error'); }
    };

    const addType = async () => {
        if (!supabase) return;
        if (!typeDraft.code.trim() || !typeDraft.name.trim()) {
            showNotification('يرجى ملء كود واسم نوع الإجازة', 'error'); return;
        }
        try {
            const { error } = await supabase.from('hr_leave_types').insert({
                code: typeDraft.code.trim().toUpperCase(), name: typeDraft.name.trim(),
                is_paid: typeDraft.is_paid, default_days_per_year: typeDraft.default_days_per_year, is_active: typeDraft.is_active,
            });
            if (error) throw error;
            showNotification('تم إضافة نوع الإجازة', 'success');
            setTypeDraft({ code: '', name: '', is_paid: true, default_days_per_year: 30, is_active: true });
            await loadAll();
        } catch (e: any) { showNotification(String(e?.message || 'تعذر الإضافة'), 'error'); }
    };

    const addBalance = async () => {
        if (!supabase) return;
        if (!balDraft.employee_id || !balDraft.leave_type_id) {
            showNotification('يرجى اختيار الموظف ونوع الإجازة', 'error'); return;
        }
        try {
            const { error } = await supabase.from('hr_leave_balances').upsert({
                employee_id: balDraft.employee_id, leave_type_id: balDraft.leave_type_id,
                year: balDraft.year, accrued_days: balDraft.accrued_days,
                last_updated_at: new Date().toISOString(),
            }, { onConflict: 'employee_id,leave_type_id,year' });
            if (error) throw error;
            showNotification('تم تحديث رصيد الإجازة', 'success');
            await loadAll();
        } catch (e: any) { showNotification(String(e?.message || 'تعذر التحديث'), 'error'); }
    };

    const statusLabel = (s: string) => {
        switch (s) {
            case 'draft': return 'مسودة';
            case 'approved': return 'موافق عليها';
            case 'rejected': return 'مرفوضة';
            case 'cancelled': return 'ملغاة';
            default: return s;
        }
    };
    const statusColor = (s: string) => {
        switch (s) {
            case 'draft': return 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300';
            case 'approved': return 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300';
            case 'rejected': return 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300';
            case 'cancelled': return 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300';
            default: return 'bg-gray-100 text-gray-800';
        }
    };

    if (loading) return <PageLoader />;

    return (
        <div className="p-6 space-y-6">
            <div className="flex items-center justify-between gap-3">
                <div>
                    <h1 className="text-2xl font-bold dark:text-white">إدارة الإجازات</h1>
                    <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">طلبات الإجازات وأرصدة الموظفين وأنواع الإجازات.</p>
                </div>
                <div className="flex items-center gap-2">
                    {(['requests', 'balances', 'types'] as const).map(t => (
                        <button key={t} type="button" onClick={() => setTab(t)}
                            className={`px-3 py-2 rounded-lg text-sm font-semibold ${tab === t ? 'bg-gray-900 text-white' : 'border border-gray-200 dark:border-gray-700 text-gray-700 dark:text-gray-200'}`}>
                            {t === 'requests' ? 'الطلبات' : t === 'balances' ? 'الأرصدة' : 'أنواع الإجازات'}
                        </button>
                    ))}
                </div>
            </div>

            {tab === 'requests' && (
                <div className="space-y-4">
                    {/* New Request Form */}
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4">
                        <div className="font-semibold text-gray-700 dark:text-gray-200 mb-3">طلب إجازة جديد</div>
                        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الموظف</div>
                                <select value={reqDraft.employee_id} onChange={e => setReqDraft(p => ({ ...p, employee_id: e.target.value }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm">
                                    <option value="">اختر...</option>
                                    {employees.filter(e => e.is_active).map(e => <option key={e.id} value={e.id}>{e.full_name}</option>)}
                                </select>
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">نوع الإجازة</div>
                                <select value={reqDraft.leave_type_id} onChange={e => setReqDraft(p => ({ ...p, leave_type_id: e.target.value }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm">
                                    <option value="">اختر...</option>
                                    {leaveTypes.filter(t => t.is_active).map(t => <option key={t.id} value={t.id}>{t.name} {t.is_paid ? '(مدفوعة)' : '(بدون راتب)'}</option>)}
                                </select>
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">من تاريخ</div>
                                <input type="date" value={reqDraft.start_date} onChange={e => setReqDraft(p => ({ ...p, start_date: e.target.value }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" />
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">إلى تاريخ</div>
                                <input type="date" value={reqDraft.end_date} onChange={e => setReqDraft(p => ({ ...p, end_date: e.target.value }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" />
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">عدد الأيام</div>
                                <input type="number" value={reqDraft.total_days} onChange={e => setReqDraft(p => ({ ...p, total_days: Number(e.target.value) }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" />
                            </div>
                            <div className="md:col-span-2">
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">ملاحظات</div>
                                <input value={reqDraft.notes} onChange={e => setReqDraft(p => ({ ...p, notes: e.target.value }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" placeholder="سبب الإجازة..." />
                            </div>
                            <div className="flex items-end">
                                <button type="button" onClick={() => void addRequest()} className="px-4 py-2 rounded-lg bg-emerald-600 text-white font-semibold text-sm w-full">إضافة الطلب</button>
                            </div>
                        </div>
                    </div>

                    {/* Requests Table */}
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 overflow-x-auto">
                        <table className="min-w-[900px] w-full text-right">
                            <thead className="bg-gray-50 dark:bg-gray-700/50">
                                <tr>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الموظف</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">نوع الإجازة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">من</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">إلى</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الأيام</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الحالة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300">إجراءات</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                                {requests.length === 0 ? (
                                    <tr><td colSpan={7} className="p-8 text-center text-gray-500 dark:text-gray-400">لا توجد طلبات إجازة.</td></tr>
                                ) : requests.map(r => (
                                    <tr key={r.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/30">
                                        <td className="p-3 text-sm dark:text-gray-200 border-r dark:border-gray-700">{r.employee_name}</td>
                                        <td className="p-3 text-sm dark:text-gray-200 border-r dark:border-gray-700">{r.leave_type_name}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{r.start_date}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{r.end_date}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{r.total_days}</td>
                                        <td className="p-3 text-sm border-r dark:border-gray-700">
                                            <span className={`px-2 py-1 rounded-full text-xs font-semibold ${statusColor(r.status)}`}>{statusLabel(r.status)}</span>
                                        </td>
                                        <td className="p-3 text-sm">
                                            {r.status === 'draft' && (
                                                <div className="flex gap-1">
                                                    <button type="button" onClick={() => void updateRequestStatus(r.id, 'approved')} className="px-2 py-1 rounded bg-green-600 text-white text-xs font-semibold">قبول</button>
                                                    <button type="button" onClick={() => void updateRequestStatus(r.id, 'rejected')} className="px-2 py-1 rounded bg-red-600 text-white text-xs font-semibold">رفض</button>
                                                </div>
                                            )}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                </div>
            )}

            {tab === 'balances' && (
                <div className="space-y-4">
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4">
                        <div className="font-semibold text-gray-700 dark:text-gray-200 mb-3">تعيين رصيد إجازة</div>
                        <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الموظف</div>
                                <select value={balDraft.employee_id} onChange={e => setBalDraft(p => ({ ...p, employee_id: e.target.value }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm">
                                    <option value="">اختر...</option>
                                    {employees.filter(e => e.is_active).map(e => <option key={e.id} value={e.id}>{e.full_name}</option>)}
                                </select>
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">نوع الإجازة</div>
                                <select value={balDraft.leave_type_id} onChange={e => setBalDraft(p => ({ ...p, leave_type_id: e.target.value }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm">
                                    <option value="">اختر...</option>
                                    {leaveTypes.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
                                </select>
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">السنة</div>
                                <input type="number" value={balDraft.year} onChange={e => setBalDraft(p => ({ ...p, year: Number(e.target.value) }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" />
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">أيام مستحقة</div>
                                <input type="number" value={balDraft.accrued_days} onChange={e => setBalDraft(p => ({ ...p, accrued_days: Number(e.target.value) }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" />
                            </div>
                            <div className="flex items-end">
                                <button type="button" onClick={() => void addBalance()} className="px-4 py-2 rounded-lg bg-emerald-600 text-white font-semibold text-sm w-full">حفظ الرصيد</button>
                            </div>
                        </div>
                    </div>
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 overflow-x-auto">
                        <table className="min-w-[700px] w-full text-right">
                            <thead className="bg-gray-50 dark:bg-gray-700/50">
                                <tr>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الموظف</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">نوع الإجازة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">السنة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">مستحقة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">مستخدمة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300">المتبقية</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                                {balances.length === 0 ? (
                                    <tr><td colSpan={6} className="p-8 text-center text-gray-500 dark:text-gray-400">لا توجد أرصدة إجازات.</td></tr>
                                ) : balances.map(b => (
                                    <tr key={b.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/30">
                                        <td className="p-3 text-sm dark:text-gray-200 border-r dark:border-gray-700">{b.employee_name}</td>
                                        <td className="p-3 text-sm dark:text-gray-200 border-r dark:border-gray-700">{b.leave_type_name}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{b.year}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{b.accrued_days}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{b.taken_days}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200" dir="ltr">
                                            <span className={b.balance_days <= 0 ? 'text-red-600 dark:text-red-400 font-bold' : 'text-emerald-600 dark:text-emerald-400 font-bold'}>{b.balance_days}</span>
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                </div>
            )}

            {tab === 'types' && (
                <div className="space-y-4">
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4">
                        <div className="font-semibold text-gray-700 dark:text-gray-200 mb-3">إضافة نوع إجازة</div>
                        <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الكود</div>
                                <input value={typeDraft.code} onChange={e => setTypeDraft(p => ({ ...p, code: e.target.value }))} placeholder="مثل: ANNUAL"
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm font-mono" />
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الاسم</div>
                                <input value={typeDraft.name} onChange={e => setTypeDraft(p => ({ ...p, name: e.target.value }))} placeholder="إجازة سنوية"
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" />
                            </div>
                            <div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">أيام مقررة/سنة</div>
                                <input type="number" value={typeDraft.default_days_per_year} onChange={e => setTypeDraft(p => ({ ...p, default_days_per_year: Number(e.target.value) }))}
                                    className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm" />
                            </div>
                            <div className="flex items-center gap-4 pt-5">
                                <label className="flex items-center gap-1 text-sm dark:text-gray-200">
                                    <input type="checkbox" checked={typeDraft.is_paid} onChange={e => setTypeDraft(p => ({ ...p, is_paid: e.target.checked }))} /> مدفوعة
                                </label>
                                <label className="flex items-center gap-1 text-sm dark:text-gray-200">
                                    <input type="checkbox" checked={typeDraft.is_active} onChange={e => setTypeDraft(p => ({ ...p, is_active: e.target.checked }))} /> فعّال
                                </label>
                            </div>
                            <div className="flex items-end">
                                <button type="button" onClick={() => void addType()} className="px-4 py-2 rounded-lg bg-emerald-600 text-white font-semibold text-sm w-full">إضافة</button>
                            </div>
                        </div>
                    </div>
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 overflow-x-auto">
                        <table className="min-w-[600px] w-full text-right">
                            <thead className="bg-gray-50 dark:bg-gray-700/50">
                                <tr>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الكود</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الاسم</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">مدفوعة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">أيام/سنة</th>
                                    <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300">الحالة</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                                {leaveTypes.length === 0 ? (
                                    <tr><td colSpan={5} className="p-8 text-center text-gray-500 dark:text-gray-400">لا توجد أنواع إجازات.</td></tr>
                                ) : leaveTypes.map(t => (
                                    <tr key={t.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/30">
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700">{t.code}</td>
                                        <td className="p-3 text-sm dark:text-gray-200 border-r dark:border-gray-700">{t.name}</td>
                                        <td className="p-3 text-sm dark:text-gray-200 border-r dark:border-gray-700">{t.is_paid ? 'نعم' : 'لا'}</td>
                                        <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{t.default_days_per_year}</td>
                                        <td className="p-3 text-sm dark:text-gray-200">{t.is_active ? 'فعّال' : 'موقّف'}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                </div>
            )}
        </div>
    );
}
