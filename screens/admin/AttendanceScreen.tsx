import { useCallback, useEffect, useState } from 'react';
import { getSupabaseClient } from '../../supabase';
import PageLoader from '../../components/PageLoader';
import { useToast } from '../../contexts/ToastContext';

type Employee = { id: string; full_name: string; employee_code?: string | null; is_active: boolean };
type AttendanceRow = {
    id: string;
    employee_id: string;
    work_date: string;
    hours_worked: number;
    overtime_hours: number;
    overtime_rate_multiplier: number;
    absence_days: number;
    employee_name?: string;
};

export default function AttendanceScreen() {
    const { showNotification } = useToast();
    const supabase = getSupabaseClient();
    const [loading, setLoading] = useState(true);
    const [employees, setEmployees] = useState<Employee[]>([]);
    const [records, setRecords] = useState<AttendanceRow[]>([]);
    const [filterMonth, setFilterMonth] = useState(() => {
        const d = new Date();
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
    });
    const [filterEmployeeId, setFilterEmployeeId] = useState('');

    // Draft for new record
    const [draft, setDraft] = useState({
        employee_id: '',
        work_date: new Date().toISOString().split('T')[0],
        hours_worked: 8,
        overtime_hours: 0,
        overtime_rate_multiplier: 1.5,
        absence_days: 0,
    });

    const loadEmployees = useCallback(async () => {
        if (!supabase) return;
        const { data, error } = await supabase.from('payroll_employees').select('id,full_name,employee_code,is_active').order('full_name');
        if (error) throw error;
        setEmployees((Array.isArray(data) ? data : []).map((e: any) => ({
            id: String(e.id), full_name: String(e.full_name || ''), employee_code: e.employee_code ? String(e.employee_code) : null, is_active: Boolean(e.is_active),
        })));
    }, [supabase]);

    const loadRecords = useCallback(async () => {
        if (!supabase) return;
        const [year, month] = filterMonth.split('-').map(Number);
        const startDate = `${year}-${String(month).padStart(2, '0')}-01`;
        const endDate = new Date(year, month, 0).toISOString().split('T')[0]; // last day of month

        let query = supabase
            .from('payroll_attendance')
            .select('id,employee_id,work_date,hours_worked,overtime_hours,overtime_rate_multiplier,absence_days,payroll_employees(full_name)')
            .gte('work_date', startDate)
            .lte('work_date', endDate)
            .order('work_date', { ascending: false });

        if (filterEmployeeId) {
            query = query.eq('employee_id', filterEmployeeId);
        }

        const { data, error } = await query;
        if (error) throw error;
        setRecords((Array.isArray(data) ? data : []).map((r: any) => ({
            id: String(r.id),
            employee_id: String(r.employee_id),
            work_date: String(r.work_date || ''),
            hours_worked: Number(r.hours_worked || 0),
            overtime_hours: Number(r.overtime_hours || 0),
            overtime_rate_multiplier: Number(r.overtime_rate_multiplier || 1.5),
            absence_days: Number(r.absence_days || 0),
            employee_name: String(r?.payroll_employees?.full_name || ''),
        })));
    }, [supabase, filterMonth, filterEmployeeId]);

    useEffect(() => {
        (async () => {
            setLoading(true);
            try {
                await loadEmployees();
                await loadRecords();
            } catch (e: any) {
                showNotification(String(e?.message || 'تعذر تحميل البيانات'), 'error');
            } finally {
                setLoading(false);
            }
        })();
    }, [loadEmployees, loadRecords, showNotification]);

    const addRecord = async () => {
        if (!supabase) return;
        if (!draft.employee_id) {
            showNotification('يرجى اختيار الموظف', 'error');
            return;
        }
        if (!draft.work_date) {
            showNotification('يرجى تحديد التاريخ', 'error');
            return;
        }
        try {
            const { error } = await supabase.from('payroll_attendance').upsert({
                employee_id: draft.employee_id,
                work_date: draft.work_date,
                hours_worked: draft.hours_worked,
                overtime_hours: draft.overtime_hours,
                overtime_rate_multiplier: draft.overtime_rate_multiplier,
                absence_days: draft.absence_days,
            }, { onConflict: 'employee_id,work_date' });
            if (error) throw error;
            showNotification('تم حفظ سجل الحضور بنجاح', 'success');
            setDraft(prev => ({ ...prev, overtime_hours: 0, absence_days: 0 }));
            await loadRecords();
        } catch (e: any) {
            showNotification(String(e?.message || 'تعذر حفظ السجل'), 'error');
        }
    };

    const deleteRecord = async (id: string) => {
        if (!supabase) return;
        if (!window.confirm('هل تريد حذف هذا السجل؟')) return;
        try {
            const { error } = await supabase.from('payroll_attendance').delete().eq('id', id);
            if (error) throw error;
            showNotification('تم حذف السجل', 'success');
            await loadRecords();
        } catch (e: any) {
            showNotification(String(e?.message || 'تعذر الحذف'), 'error');
        }
    };

    if (loading) return <PageLoader />;

    const activeEmployees = employees.filter(e => e.is_active);

    return (
        <div className="p-6 space-y-6">
            <div>
                <h1 className="text-2xl font-bold dark:text-white">الحضور والإضافي والغياب</h1>
                <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
                    سجّل حضور الموظفين وساعات العمل الإضافي وأيام الغياب ليتم احتسابها تلقائياً في مسير الرواتب.
                </p>
            </div>

            {/* Add New Record */}
            <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4">
                <div className="font-semibold text-gray-700 dark:text-gray-200 mb-3">تسجيل جديد</div>
                <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الموظف</div>
                        <select
                            value={draft.employee_id}
                            onChange={e => setDraft(prev => ({ ...prev, employee_id: e.target.value }))}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        >
                            <option value="">اختر موظف...</option>
                            {activeEmployees.map(e => (
                                <option key={e.id} value={e.id}>{e.full_name}{e.employee_code ? ` (${e.employee_code})` : ''}</option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">التاريخ</div>
                        <input
                            type="date"
                            value={draft.work_date}
                            onChange={e => setDraft(prev => ({ ...prev, work_date: e.target.value }))}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        />
                    </div>
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">ساعات العمل</div>
                        <input
                            type="number"
                            min="0"
                            step="0.5"
                            value={draft.hours_worked}
                            onChange={e => setDraft(prev => ({ ...prev, hours_worked: Number(e.target.value) }))}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        />
                    </div>
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">أيام الغياب</div>
                        <input
                            type="number"
                            min="0"
                            step="0.5"
                            value={draft.absence_days}
                            onChange={e => setDraft(prev => ({ ...prev, absence_days: Number(e.target.value) }))}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        />
                    </div>
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">ساعات إضافي</div>
                        <input
                            type="number"
                            min="0"
                            step="0.5"
                            value={draft.overtime_hours}
                            onChange={e => setDraft(prev => ({ ...prev, overtime_hours: Number(e.target.value) }))}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        />
                    </div>
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">معامل الإضافي</div>
                        <input
                            type="number"
                            min="1"
                            step="0.25"
                            value={draft.overtime_rate_multiplier}
                            onChange={e => setDraft(prev => ({ ...prev, overtime_rate_multiplier: Number(e.target.value) }))}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        />
                    </div>
                    <div className="flex items-end">
                        <button
                            type="button"
                            onClick={() => void addRecord()}
                            className="px-4 py-2 rounded-lg bg-emerald-600 text-white font-semibold text-sm w-full"
                        >
                            حفظ السجل
                        </button>
                    </div>
                </div>
            </div>

            {/* Filters */}
            <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4">
                <div className="font-semibold text-gray-700 dark:text-gray-200 mb-3">تصفية السجلات</div>
                <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الشهر</div>
                        <input
                            type="month"
                            value={filterMonth}
                            onChange={e => setFilterMonth(e.target.value)}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        />
                    </div>
                    <div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الموظف (اختياري)</div>
                        <select
                            value={filterEmployeeId}
                            onChange={e => setFilterEmployeeId(e.target.value)}
                            className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm"
                        >
                            <option value="">جميع الموظفين</option>
                            {employees.map(e => (
                                <option key={e.id} value={e.id}>{e.full_name}</option>
                            ))}
                        </select>
                    </div>
                    <div className="flex items-end">
                        <button type="button" onClick={() => void loadRecords()} className="px-4 py-2 rounded-lg bg-gray-900 text-white font-semibold text-sm w-full">بحث</button>
                    </div>
                </div>
            </div>

            {/* Records Table */}
            <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 overflow-x-auto">
                <table className="min-w-[800px] w-full text-right">
                    <thead className="bg-gray-50 dark:bg-gray-700/50">
                        <tr>
                            <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الموظف</th>
                            <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">التاريخ</th>
                            <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">ساعات العمل</th>
                            <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">غياب (أيام)</th>
                            <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">إضافي (ساعات)</th>
                            <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">معامل الإضافي</th>
                            <th className="p-3 text-xs font-semibold text-gray-600 dark:text-gray-300">إجراءات</th>
                        </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                        {records.length === 0 ? (
                            <tr><td colSpan={7} className="p-8 text-center text-gray-500 dark:text-gray-400">لا توجد سجلات لهذا الشهر.</td></tr>
                        ) : records.map(r => (
                            <tr key={r.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/30">
                                <td className="p-3 text-sm dark:text-gray-200 border-r dark:border-gray-700">{r.employee_name || '—'}</td>
                                <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{r.work_date}</td>
                                <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{r.hours_worked}</td>
                                <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">
                                    {r.absence_days > 0 ? <span className="text-red-600 dark:text-red-400 font-semibold">{r.absence_days}</span> : '0'}
                                </td>
                                <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">
                                    {r.overtime_hours > 0 ? <span className="text-emerald-600 dark:text-emerald-400 font-semibold">{r.overtime_hours}</span> : '0'}
                                </td>
                                <td className="p-3 text-sm font-mono dark:text-gray-200 border-r dark:border-gray-700" dir="ltr">{r.overtime_rate_multiplier}x</td>
                                <td className="p-3 text-sm">
                                    <button type="button" onClick={() => void deleteRecord(r.id)} className="px-3 py-1 rounded bg-red-600 text-white text-xs font-semibold">حذف</button>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </div>
    );
}
