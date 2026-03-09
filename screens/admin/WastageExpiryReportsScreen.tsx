import React, { useEffect, useMemo, useState } from 'react';
import { getBaseCurrencyCode, getSupabaseClient } from '../../supabase';
import type { AccountingLightEntry } from '../../types';
import { useToast } from '../../contexts/ToastContext';
import { useSettings } from '../../contexts/SettingsContext';
import { exportToXlsx, sharePdf } from '../../utils/export';
import { buildPdfBrandOptions, buildXlsxBrandOptions } from '../../utils/branding';
import { toYmdLocal } from '../../utils/dateUtils';

const WastageExpiryReportsScreen: React.FC = () => {
  const supabase = useMemo(() => getSupabaseClient(), []);
  const { showNotification } = useToast();
  const { settings } = useSettings();
  const [entries, setEntries] = useState<AccountingLightEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [isSharing, setIsSharing] = useState(false);
  const [filterType, setFilterType] = useState<'all' | 'wastage' | 'expiry'>('all');
  const [baseCode, setBaseCode] = useState('—');

  // Date filters
  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
  const [startDate, setStartDate] = useState(toYmdLocal(monthStart));
  const [endDate, setEndDate] = useState(toYmdLocal(now));
  const [rangePreset, setRangePreset] = useState<'today' | 'week' | 'month' | 'year' | 'all'>('month');

  useEffect(() => {
    void getBaseCurrencyCode().then((c) => {
      if (!c) return;
      setBaseCode(c);
    });
  }, []);

  const applyPreset = (preset: typeof rangePreset) => {
    setRangePreset(preset);
    if (preset === 'all') {
      setStartDate('');
      setEndDate('');
      return;
    }
    const today = new Date();
    const start = new Date(today);
    const end = new Date(today);
    if (preset === 'today') {
      // no changes
    } else if (preset === 'week') {
      const day = today.getDay();
      const diff = (day + 6) % 7;
      start.setDate(today.getDate() - diff);
    } else if (preset === 'month') {
      start.setDate(1);
    } else if (preset === 'year') {
      start.setMonth(0, 1);
    }
    setStartDate(toYmdLocal(start));
    setEndDate(toYmdLocal(end));
  };

  const load = async () => {
    if (!supabase) return;
    try {
      setLoading(true);
      let query = supabase.from('accounting_light_entries').select('*').order('occurred_at', { ascending: false });

      if (filterType !== 'all') {
        query = query.eq('entry_type', filterType);
      }
      if (startDate) {
        query = query.gte('occurred_at', `${startDate}T00:00:00`);
      }
      if (endDate) {
        query = query.lte('occurred_at', `${endDate}T23:59:59`);
      }
      query = query.limit(2000);

      const { data, error } = await query;
      if (error) throw error;
      const list: AccountingLightEntry[] = (data || []).map((row: any) => ({
        id: String(row.id),
        entryType: (String(row.entry_type) === 'wastage' ? 'wastage' : 'expiry'),
        itemId: String(row.item_id),
        warehouseId: row.warehouse_id ? String(row.warehouse_id) : undefined,
        batchId: row.batch_id ? String(row.batch_id) : undefined,
        quantity: Number(row.quantity || 0),
        unit: row.unit ? String(row.unit) : undefined,
        unitCost: Number(row.unit_cost || 0),
        totalCost: Number(row.total_cost || 0),
        occurredAt: String(row.occurred_at),
        debitAccount: String(row.debit_account || ''),
        creditAccount: String(row.credit_account || ''),
        createdBy: row.created_by ? String(row.created_by) : undefined,
        createdAt: String(row.created_at),
        notes: row.notes ? String(row.notes) : undefined,
        sourceRef: row.source_ref ? String(row.source_ref) : undefined,
      }));
      setEntries(list);
    } catch {
      setEntries([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void load();
  }, [filterType, startDate, endDate]);

  const summary = useMemo(() => {
    let wastageCount = 0;
    let expiryCount = 0;
    let totalCost = 0;
    let totalQty = 0;
    for (const e of entries) {
      if (e.entryType === 'wastage') wastageCount++;
      else expiryCount++;
      totalCost += e.totalCost;
      totalQty += e.quantity;
    }
    return { wastageCount, expiryCount, totalCost, totalQty };
  }, [entries]);

  const filtersText = useMemo(() => {
    const parts: string[] = [];
    if (filterType === 'wastage') parts.push('النوع: هدر');
    else if (filterType === 'expiry') parts.push('النوع: انتهاء');
    else parts.push('النوع: الكل');
    if (startDate && endDate) parts.push(`الفترة: ${startDate} → ${endDate}`);
    else parts.push('الفترة: الكل');
    return parts.join(' • ');
  }, [filterType, startDate, endDate]);

  const handleExportXlsx = async () => {
    const headers = [
      'التاريخ', 'النوع', 'الصنف', 'المخزن', 'الدفعة',
      'الكمية', 'التكلفة/وحدة', 'الإجمالي', 'مدين', 'دائن', 'ملاحظة',
    ];
    const rows = entries.map(e => [
      new Date(e.occurredAt).toLocaleString('ar-EG-u-nu-latn'),
      e.entryType === 'wastage' ? 'هدر' : 'انتهاء',
      e.itemId.slice(-6).toUpperCase(),
      e.warehouseId ? e.warehouseId.slice(-6).toUpperCase() : '-',
      e.batchId ? e.batchId.slice(0, 8) : '-',
      Number(e.quantity),
      Number(e.unitCost.toFixed(2)),
      Number(e.totalCost.toFixed(2)),
      e.debitAccount,
      e.creditAccount,
      e.notes || '',
    ]);
    const ok = await exportToXlsx(
      headers,
      rows,
      `wastage_expiry_${startDate || 'all'}_to_${endDate || 'all'}.xlsx`,
      {
        sheetName: 'WastageExpiry',
        currencyColumns: [7, 8],
        currencyFormat: '#,##0.00',
        ...buildXlsxBrandOptions(settings, 'تقارير الهدر والانتهاء', headers.length, { periodText: filtersText }),
      }
    );
    showNotification(ok ? 'تم حفظ التقرير في مجلد المستندات' : 'فشل تصدير الملف.', ok ? 'success' : 'error');
  };

  const handleSharePdf = async () => {
    setIsSharing(true);
    const ok = await sharePdf(
      'wastage-print-area',
      'تقارير الهدر والانتهاء',
      `wastage_expiry_${startDate || 'all'}_to_${endDate || 'all'}.pdf`,
      buildPdfBrandOptions(settings, `تقارير الهدر والانتهاء • ${filtersText}`, { pageNumbers: true })
    );
    showNotification(ok ? 'تم حفظ التقرير في مجلد المستندات' : 'فشل مشاركة الملف.', ok ? 'success' : 'error');
    setIsSharing(false);
  };

  return (
    <div className="max-w-6xl mx-auto p-6 space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h1 className="text-3xl font-bold bg-clip-text text-transparent bg-gradient-to-l from-primary-600 to-gold-500">تقارير الهدر والانتهاء</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">قيود خفيفة — حركات هدر وانتهاء الصلاحية</p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => void handleExportXlsx()}
            disabled={entries.length === 0}
            className="px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 text-sm font-semibold text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-60"
          >
            تصدير Excel
          </button>
          <button
            type="button"
            onClick={() => void handleSharePdf()}
            disabled={entries.length === 0 || isSharing}
            className="px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 text-sm font-semibold text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-60"
          >
            PDF
          </button>
        </div>
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4 text-center">
          <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">حالات هدر</div>
          <div className="text-2xl font-bold text-red-600 font-mono">{summary.wastageCount}</div>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4 text-center">
          <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">حالات انتهاء</div>
          <div className="text-2xl font-bold text-orange-600 font-mono">{summary.expiryCount}</div>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4 text-center">
          <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">إجمالي الكمية</div>
          <div className="text-2xl font-bold dark:text-white font-mono">{summary.totalQty.toLocaleString('ar-EG-u-nu-latn')}</div>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4 text-center">
          <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">إجمالي التكلفة</div>
          <div className="text-2xl font-bold text-primary-700 dark:text-primary-300 font-mono">{summary.totalCost.toLocaleString('ar-EG-u-nu-latn', { minimumFractionDigits: 2 })} {baseCode}</div>
        </div>
      </div>

      {/* Filters */}
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg border border-gray-100 dark:border-gray-700 p-4 space-y-3">
        <div className="grid grid-cols-1 md:grid-cols-4 gap-3 items-end">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">النوع</label>
            <select
              value={filterType}
              onChange={(e) => setFilterType(e.target.value as any)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
            >
              <option value="all">الكل</option>
              <option value="wastage">هدر</option>
              <option value="expiry">انتهاء</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">من</label>
            <input
              type="date"
              value={startDate}
              onChange={(e) => { setStartDate(e.target.value); setRangePreset('all'); }}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">إلى</label>
            <input
              type="date"
              value={endDate}
              onChange={(e) => { setEndDate(e.target.value); setRangePreset('all'); }}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
            />
          </div>
          <div className="flex items-center gap-2 flex-wrap">
            {(['today', 'week', 'month', 'year', 'all'] as const).map((p) => (
              <button
                key={p}
                onClick={() => applyPreset(p)}
                className={`px-3 py-2 rounded-lg text-sm border ${rangePreset === p ? 'bg-orange-500 text-white border-orange-500' : 'border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200'}`}
              >
                {p === 'today' ? 'اليوم' : p === 'week' ? 'الأسبوع' : p === 'month' ? 'الشهر' : p === 'year' ? 'السنة' : 'الكل'}
              </button>
            ))}
          </div>
        </div>
        <div className="flex items-center justify-between">
          <div className="text-sm text-gray-500 dark:text-gray-400">
            عدد السجلات: <span className="font-semibold font-mono">{entries.length}</span>
          </div>
          {loading && <span className="text-xs text-gray-500 dark:text-gray-400">جاري التحميل...</span>}
        </div>
      </div>

      {/* Table */}
      <div id="wastage-print-area" className="bg-white dark:bg-gray-800 rounded-xl shadow-lg border border-gray-100 dark:border-gray-700 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm text-right">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">التاريخ</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">النوع</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الصنف</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">المخزن</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الدفعة</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الكمية</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">التكلفة/وحدة</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الإجمالي</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">مدين</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">دائن</th>
                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-300">ملاحظة</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
              {entries.map(e => (
                <tr key={e.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/30 transition-colors">
                  <td className="p-3 whitespace-nowrap border-r dark:border-gray-700">{new Date(e.occurredAt).toLocaleString('ar-EG-u-nu-latn')}</td>
                  <td className="p-3 border-r dark:border-gray-700">
                    <span className={`px-2 py-1 rounded-full text-xs font-semibold ${e.entryType === 'wastage' ? 'bg-red-100 text-red-800 dark:bg-red-900/20 dark:text-red-300' : 'bg-orange-100 text-orange-800 dark:bg-orange-900/20 dark:text-orange-300'}`}>
                      {e.entryType === 'wastage' ? 'هدر' : 'انتهاء'}
                    </span>
                  </td>
                  <td className="p-3 font-mono border-r dark:border-gray-700">{e.itemId.slice(-6).toUpperCase()}</td>
                  <td className="p-3 font-mono border-r dark:border-gray-700">{e.warehouseId ? e.warehouseId.slice(-6).toUpperCase() : '-'}</td>
                  <td className="p-3 font-mono border-r dark:border-gray-700">{e.batchId ? e.batchId.slice(0, 8) : '-'}</td>
                  <td className="p-3 font-mono border-r dark:border-gray-700">{e.quantity}</td>
                  <td className="p-3 font-mono border-r dark:border-gray-700">{e.unitCost.toFixed(2)} {baseCode}</td>
                  <td className="p-3 font-semibold font-mono border-r dark:border-gray-700">{e.totalCost.toFixed(2)} {baseCode}</td>
                  <td className="p-3 font-mono border-r dark:border-gray-700">{e.debitAccount}</td>
                  <td className="p-3 font-mono border-r dark:border-gray-700">{e.creditAccount}</td>
                  <td className="p-3">{e.notes || ''}</td>
                </tr>
              ))}
              {entries.length === 0 && !loading && (
                <tr>
                  <td className="p-8 text-center text-gray-500 dark:text-gray-400" colSpan={11}>لا توجد بيانات ضمن الفترة المحددة</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};

export default WastageExpiryReportsScreen;
