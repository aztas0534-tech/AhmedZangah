import React, { useEffect, useMemo, useState } from 'react';
import { getSupabaseClient } from '../../supabase';
import { useToast } from '../../contexts/ToastContext';
import { useAuth } from '../../contexts/AuthContext';
import { localizeSupabaseError } from '../../utils/errorUtils';
import Spinner from '../../components/Spinner';

type TableDef = { key: string; label: string };

const TABLES: TableDef[] = [
  { key: 'menu_items', label: 'الأصناف' },
  { key: 'orders', label: 'الطلبات' },
  { key: 'order_events', label: 'أحداث الطلبات' },
  { key: 'customers', label: 'العملاء' },
  { key: 'reviews', label: 'التقييمات' },
  { key: 'coupons', label: 'الكوبونات' },
  { key: 'addons', label: 'الإضافات' },
  { key: 'ads', label: 'الإعلانات' },
  { key: 'delivery_zones', label: 'مناطق التوصيل' },
  { key: 'app_settings', label: 'إعدادات التطبيق' },
  { key: 'admin_users', label: 'مستخدمي لوحة التحكم' },
  { key: 'item_categories', label: 'فئات الأصناف' },
  { key: 'item_groups', label: 'مجموعات الأصناف' },
  { key: 'unit_types', label: 'أنواع الوحدات' },
  { key: 'freshness_levels', label: 'درجات الطزاجة' },
  { key: 'banks', label: 'البنوك' },
  { key: 'transfer_recipients', label: 'مستلمو الشبكات' },
  { key: 'stock_management', label: 'إدارة المخزون' },
  { key: 'stock_history', label: 'سجل المخزون' },
  { key: 'price_history', label: 'سجل الأسعار' },
  { key: 'currencies', label: 'العملات' },
  { key: 'fx_rates', label: 'أسعار الصرف' },
  { key: 'inventory_movements', label: 'حركات المخزون' },
  { key: 'order_item_cogs', label: 'تكلفة أصناف الطلب' },
  { key: 'payments', label: 'المدفوعات' },
  { key: 'cash_shifts', label: 'وردية النقد' },
  { key: 'suppliers', label: 'الموردون' },
  { key: 'purchase_orders', label: 'أوامر الشراء' },
  { key: 'purchase_items', label: 'أصناف الشراء' },
  { key: 'purchase_receipts', label: 'إيصالات الشراء' },
  { key: 'purchase_receipt_items', label: 'أصناف إيصالات الشراء' },
  { key: 'purchase_returns', label: 'مرتجعات الشراء' },
  { key: 'purchase_return_items', label: 'أصناف مرتجعات الشراء' },
  { key: 'stock_wastage', label: 'تالف المخزون' },
  { key: 'system_audit_logs', label: 'سجل النظام' },
  { key: 'cost_centers', label: 'مراكز التكلفة' },
  { key: 'chart_of_accounts', label: 'دليل الحسابات' },
  { key: 'journal_entries', label: 'قيود اليومية' },
  { key: 'journal_lines', label: 'تفاصيل القيود' },
  { key: 'accounting_periods', label: 'الفترات المحاسبية' },
  { key: 'sales_returns', label: 'مرتجعات المبيعات' },
  { key: 'production_orders', label: 'أوامر الإنتاج' },
  { key: 'production_order_inputs', label: 'مدخلات الإنتاج' },
  { key: 'production_order_outputs', label: 'مخرجات الإنتاج' },
  { key: 'notifications', label: 'الإشعارات' },
];

const PAGE_SIZE = 50;

const DatabaseExplorerScreen: React.FC = () => {
  const [selectedTable, setSelectedTable] = useState<string>(TABLES[0]?.key || '');
  const [rows, setRows] = useState<any[]>([]);
  const [columns, setColumns] = useState<string[]>([]);
  const [page, setPage] = useState<number>(1);
  const [totalCount, setTotalCount] = useState<number>(0);
  const [loading, setLoading] = useState<boolean>(false);
  const [query, setQuery] = useState<string>('');
  const [schemaHealth, setSchemaHealth] = useState<{ ok: boolean; appliedVersion: string; missing: string[] } | null>(null);
  const [repairPreview, setRepairPreview] = useState<any | null>(null);
  const [repairBusy, setRepairBusy] = useState<boolean>(false);
  const [cogsAudit, setCogsAudit] = useState<any | null>(null);
  const [cogsRepair, setCogsRepair] = useState<any | null>(null);
  const [cogsBusy, setCogsBusy] = useState<boolean>(false);
  const [cogsStart, setCogsStart] = useState<string>('');
  const [cogsEnd, setCogsEnd] = useState<string>('');
  const { showNotification } = useToast();
  const { hasPermission } = useAuth();

  useEffect(() => {
    if (!hasPermission('settings.manage')) {
      showNotification('هذه الصفحة تتطلب صلاحية الإعدادات.', 'error');
    }
  }, [hasPermission, showNotification]);

  const supabase = getSupabaseClient();

  const runSchemaHealthcheck = async () => {
    if (!supabase) return;
    try {
      const { data, error } = await supabase.rpc('app_schema_healthcheck');
      if (error) throw error;
      const d: any = data || {};
      const ok = Boolean(d?.ok);
      const appliedVersion = String(d?.appliedVersion || '');
      const missing = Array.isArray(d?.missing) ? d.missing.map((x: any) => String(x)) : [];
      setSchemaHealth({ ok, appliedVersion, missing });
      showNotification(ok ? 'قاعدة البيانات متوافقة.' : 'قاعدة البيانات تحتاج هجرات/دوال مفقودة.', ok ? 'success' : 'error');
    } catch (err: any) {
      setSchemaHealth(null);
      showNotification(localizeSupabaseError(err) || 'فشل فحص توافق قاعدة البيانات', 'error');
    }
  };

  const runRepairMetaDefs = async (apply: boolean) => {
    if (!supabase) return;
    setRepairBusy(true);
    try {
      const { data, error } = await supabase.rpc('repair_missing_item_meta_defs', { p_dry_run: !apply } as any);
      if (error) throw error;
      setRepairPreview(data || null);
      showNotification(apply ? 'تم إنشاء تعريفات ناقصة. راجع الأسماء وعدّلها.' : 'تم إنشاء تقرير بالناقص (Dry Run).', 'success');
    } catch (err: any) {
      showNotification(localizeSupabaseError(err) || 'فشل إصلاح تعريفات الأصناف', 'error');
    } finally {
      setRepairBusy(false);
    }
  };

  const runCogsAudit = async () => {
    if (!supabase) return;
    setCogsBusy(true);
    try {
      const { data, error } = await supabase.rpc('audit_sales_cogs', {
        p_start_date: cogsStart.trim() ? cogsStart.trim() : null,
        p_end_date: cogsEnd.trim() ? cogsEnd.trim() : null,
      } as any);
      if (error) throw error;
      setCogsAudit(data || null);
      showNotification('تم فحص تكلفة البضاعة المباعة.', 'success');
    } catch (err: any) {
      setCogsAudit(null);
      showNotification(localizeSupabaseError(err) || 'فشل فحص تكلفة البضاعة المباعة', 'error');
    } finally {
      setCogsBusy(false);
    }
  };

  const runCogsRepair = async (apply: boolean) => {
    if (!supabase) return;
    setCogsBusy(true);
    try {
      const { data, error } = await supabase.rpc('repair_sales_cogs', {
        p_start_date: cogsStart.trim() ? cogsStart.trim() : null,
        p_end_date: cogsEnd.trim() ? cogsEnd.trim() : null,
        p_dry_run: !apply,
      } as any);
      if (error) throw error;
      setCogsRepair(data || null);
      showNotification(apply ? 'تم إعادة بناء COGS للأوامر المحددة.' : 'تم إنشاء تقرير إصلاح COGS (Dry Run).', 'success');
    } catch (err: any) {
      setCogsRepair(null);
      showNotification(localizeSupabaseError(err) || 'فشل إصلاح تكلفة البضاعة المباعة', 'error');
    } finally {
      setCogsBusy(false);
    }
  };

  const fetchData = async (table: string, currentPage: number) => {
    if (!supabase) return;
    setLoading(true);
    try {
      const from = (currentPage - 1) * PAGE_SIZE;
      const to = from + PAGE_SIZE - 1;
      const sel = supabase.from(table).select('*', { count: 'exact' }).range(from, to);
      const { data, count, error } = await sel;
      if (error) throw error;
      const arr = Array.isArray(data) ? data : [];
      setRows(arr);
      setTotalCount(typeof count === 'number' ? count : arr.length);
      const keys = new Set<string>();
      arr.forEach((r: any) => {
        Object.keys(r || {}).forEach(k => keys.add(k));
      });
      setColumns(Array.from(keys));
    } catch (err: any) {
      showNotification(localizeSupabaseError(err) || 'فشل تحميل البيانات', 'error');
      setRows([]);
      setColumns([]);
      setTotalCount(0);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    setPage(1);
    void fetchData(selectedTable, 1);
  }, [selectedTable]);

  useEffect(() => {
    void fetchData(selectedTable, page);
  }, [page]);

  const filteredRows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(r =>
      columns.some(col => {
        const v = r?.[col];
        if (v == null) return false;
        const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
        return s.toLowerCase().includes(q);
      })
    );
  }, [rows, columns, query]);

  const totalPages = Math.max(1, Math.ceil(totalCount / PAGE_SIZE));

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg shadow-md p-4">
      <div className="mb-4 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => void runSchemaHealthcheck()}
            className="px-3 py-2 rounded-md bg-blue-600 hover:bg-blue-700 text-white text-sm disabled:opacity-60"
            disabled={!hasPermission('settings.manage')}
          >
            فحص توافق قاعدة البيانات
          </button>
          <button
            type="button"
            onClick={() => void runRepairMetaDefs(false)}
            className="px-3 py-2 rounded-md bg-gray-700 hover:bg-gray-800 text-white text-sm disabled:opacity-60"
            disabled={!hasPermission('settings.manage') || repairBusy}
          >
            فحص النواقص (فئات/وحدات/مجموعات)
          </button>
          <button
            type="button"
            onClick={() => void runRepairMetaDefs(true)}
            className="px-3 py-2 rounded-md bg-emerald-600 hover:bg-emerald-700 text-white text-sm disabled:opacity-60"
            disabled={!hasPermission('settings.manage') || repairBusy}
          >
            إصلاح تلقائي للنواقص
          </button>
          <button
            type="button"
            onClick={() => void runCogsAudit()}
            className="px-3 py-2 rounded-md bg-indigo-600 hover:bg-indigo-700 text-white text-sm disabled:opacity-60"
            disabled={!hasPermission('settings.manage') || cogsBusy}
          >
            فحص COGS
          </button>
          <button
            type="button"
            onClick={() => void runCogsRepair(false)}
            className="px-3 py-2 rounded-md bg-indigo-700 hover:bg-indigo-800 text-white text-sm disabled:opacity-60"
            disabled={!hasPermission('settings.manage') || cogsBusy}
          >
            تقرير إصلاح COGS
          </button>
          <button
            type="button"
            onClick={() => void runCogsRepair(true)}
            className="px-3 py-2 rounded-md bg-fuchsia-600 hover:bg-fuchsia-700 text-white text-sm disabled:opacity-60"
            disabled={!hasPermission('settings.manage') || cogsBusy}
          >
            إصلاح COGS
          </button>
        </div>
        {(repairBusy || cogsBusy) && (
          <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
            <Spinner />
            جاري التنفيذ...
          </div>
        )}
      </div>

      <div className="mb-4 grid grid-cols-1 md:grid-cols-3 gap-3">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">بداية الفترة (اختياري)</label>
          <input
            type="text"
            value={cogsStart}
            onChange={(e) => setCogsStart(e.target.value)}
            placeholder="2026-01-01T00:00:00Z"
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-gray-900 dark:text-white font-mono text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">نهاية الفترة (اختياري)</label>
          <input
            type="text"
            value={cogsEnd}
            onChange={(e) => setCogsEnd(e.target.value)}
            placeholder="2026-02-01T23:59:59Z"
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-gray-900 dark:text-white font-mono text-sm"
          />
        </div>
        <div className="text-xs text-gray-600 dark:text-gray-300 md:self-end">
          اتركها فارغة لفحص كل السجل (قد يكون ثقيلًا على الإنتاج).
        </div>
      </div>

      {schemaHealth && (
        <div className={`mb-4 p-3 rounded-md border ${schemaHealth.ok ? 'bg-green-50 border-green-200 dark:bg-green-900/20 dark:border-green-800' : 'bg-red-50 border-red-200 dark:bg-red-900/20 dark:border-red-800'}`}>
          <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
            <div className={`text-sm font-semibold ${schemaHealth.ok ? 'text-green-800 dark:text-green-200' : 'text-red-800 dark:text-red-200'}`}>
              {schemaHealth.ok ? 'متوافق' : 'غير متوافق'}
            </div>
            <div className="text-xs font-mono text-gray-600 dark:text-gray-300" dir="ltr">
              {schemaHealth.appliedVersion ? `db:${schemaHealth.appliedVersion}` : 'db:unknown'}
            </div>
          </div>
          {!schemaHealth.ok && schemaHealth.missing.length > 0 && (
            <div className="mt-2 text-xs font-mono text-red-800 dark:text-red-200" dir="ltr">
              {schemaHealth.missing.slice(0, 16).join(' • ')}{schemaHealth.missing.length > 16 ? ' • ...' : ''}
            </div>
          )}
        </div>
      )}

      {cogsAudit && (
        <div className="mb-4 p-3 rounded-md border border-indigo-200 dark:border-indigo-800 bg-indigo-50 dark:bg-indigo-900/20">
          <div className="text-sm font-semibold text-indigo-900 dark:text-indigo-200">نتيجة فحص COGS</div>
          <div className="mt-2 text-xs font-mono text-indigo-900 dark:text-indigo-200 whitespace-pre-wrap" dir="ltr">
            {JSON.stringify(cogsAudit, null, 2)}
          </div>
        </div>
      )}

      {cogsRepair && (
        <div className="mb-4 p-3 rounded-md border border-fuchsia-200 dark:border-fuchsia-800 bg-fuchsia-50 dark:bg-fuchsia-900/20">
          <div className="text-sm font-semibold text-fuchsia-900 dark:text-fuchsia-200">نتيجة إصلاح COGS</div>
          <div className="mt-2 text-xs font-mono text-fuchsia-900 dark:text-fuchsia-200 whitespace-pre-wrap" dir="ltr">
            {JSON.stringify(cogsRepair, null, 2)}
          </div>
        </div>
      )}

      {repairPreview && (
        <div className="mb-4 p-3 rounded-md border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/20">
          <div className="text-sm font-semibold text-gray-800 dark:text-gray-200">نتيجة إصلاح التعريفات</div>
          <div className="mt-2 text-xs font-mono text-gray-700 dark:text-gray-300 whitespace-pre-wrap" dir="ltr">
            {JSON.stringify(repairPreview, null, 2)}
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <div className="md:col-span-1">
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">الجدول</label>
          <select
            value={selectedTable}
            onChange={e => setSelectedTable(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
          >
            {TABLES.map(t => (
              <option key={t.key} value={t.key}>{t.label}</option>
            ))}
          </select>
        </div>
        <div className="md:col-span-2">
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">بحث</label>
          <input
            type="text"
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="ابحث داخل النتائج المعروضة..."
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
          />
        </div>
        <div className="md:col-span-1">
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">الصفحات</label>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => setPage(p => Math.max(1, p - 1))}
              className="px-3 py-2 bg-gray-200 rounded-md dark:bg-gray-700 text-gray-800 dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-600"
              disabled={page <= 1}
            >
              السابق
            </button>
            <span className="text-sm text-gray-700 dark:text-gray-300" dir="ltr">
              {page} / {totalPages}
            </span>
            <button
              type="button"
              onClick={() => setPage(p => Math.min(totalPages, p + 1))}
              className="px-3 py-2 bg-gray-200 rounded-md dark:bg-gray-700 text-gray-800 dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-600"
              disabled={page >= totalPages}
            >
              التالي
            </button>
          </div>
        </div>
      </div>

      <div className="mt-4 overflow-x-auto">
        {loading ? (
          <div className="flex items-center justify-center py-10">
            <Spinner />
          </div>
        ) : (
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead className="bg-gray-50 dark:bg-gray-900">
              <tr>
                {columns.length === 0 ? (
                  <th className="px-4 py-2 text-right text-xs font-medium text-gray-500 dark:text-gray-400">لا توجد أعمدة</th>
                ) : (
                  columns.map(col => (
                    <th key={col} className="px-4 py-2 text-right text-xs font-medium text-gray-500 dark:text-gray-400">{col}</th>
                  ))
                )}
              </tr>
            </thead>
            <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
              {filteredRows.length === 0 ? (
                <tr>
                  <td className="px-4 py-4 text-center text-sm text-gray-500 dark:text-gray-400" colSpan={Math.max(1, columns.length)}>
                    لا توجد بيانات لعرضها
                  </td>
                </tr>
              ) : (
                filteredRows.map((row, idx) => (
                  <tr key={idx}>
                    {columns.map(col => {
                      const v = row?.[col];
                      const s = v == null ? '' : (typeof v === 'object' ? JSON.stringify(v) : String(v));
                      const isNumeric = typeof v === 'number';
                      return (
                        <td key={col} className="px-4 py-2 text-sm text-gray-700 dark:text-gray-300" dir={isNumeric ? 'ltr' : undefined}>
                          {s.length > 200 ? s.slice(0, 200) + '…' : s}
                        </td>
                      );
                    })}
                  </tr>
                ))
              )}
            </tbody>
          </table>
        )}
      </div>
      <div className="mt-2 text-xs text-gray-500 dark:text-gray-400">
        إجمالي السجلات: <span dir="ltr">{totalCount}</span>
      </div>
    </div>
  );
};

export default DatabaseExplorerScreen;
