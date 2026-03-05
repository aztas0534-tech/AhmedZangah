import { useCallback, useEffect, useMemo, useState } from 'react';
import { getSupabaseClient } from '../../supabase';
import { useAuth } from '../../contexts/AuthContext';
import { useToast } from '../../contexts/ToastContext';
import { useSettings } from '../../contexts/SettingsContext';
import { printJournalVoucherByEntryId, printPaymentVoucherByEntryId, printReceiptVoucherByEntryId } from '../../utils/vouchers';


type AccountRow = { id: string; code: string; name: string; nameAr: string };
type CostCenterRow = { id: string; name: string; code: string | null };
type PartyRow = { id: string; name: string };
type VoucherHistoryRow = {
  id: string;
  entryDate: string;
  memo: string;
  status: string;
  sourceEvent: string;
  documentNumber: string;
  totalDebit: number;
  createdBy: string;
};

import { translateAccountName } from '../../utils/accountUtils';

const toDateTimeLocalInputValue = (d: Date) => {
  const pad = (n: number) => String(n).padStart(2, '0');
  const yyyy = d.getFullYear();
  const mm = pad(d.getMonth() + 1);
  const dd = pad(d.getDate());
  const hh = pad(d.getHours());
  const min = pad(d.getMinutes());
  return `${yyyy}-${mm}-${dd}T${hh}:${min}`;
};

export default function VoucherEntryScreen() {
  const { showNotification } = useToast();
  const { hasPermission, userId } = useAuth();
  const { settings } = useSettings();

  const canView = hasPermission('accounting.view') || hasPermission('accounting.manage');
  const canManage = hasPermission('accounting.manage');
  const canApprove = hasPermission('accounting.approve');
  const canVoid = hasPermission('accounting.void');

  const baseCurrencyCode = String((settings as any)?.baseCurrency || '').trim().toUpperCase() || 'YER';

  const [loading, setLoading] = useState(true);
  const [accounts, setAccounts] = useState<AccountRow[]>([]);
  const [costCenters, setCostCenters] = useState<CostCenterRow[]>([]);
  const [parties, setParties] = useState<PartyRow[]>([]);
  const [currencyOptions, setCurrencyOptions] = useState<string[]>([]);

  const [voucherType, setVoucherType] = useState<'receipt' | 'payment' | 'journal'>('receipt');
  const [occurredAt, setOccurredAt] = useState(() => toDateTimeLocalInputValue(new Date()));
  const [memo, setMemo] = useState('');
  const [amount, setAmount] = useState<string>('');
  const [debitAccountCode, setDebitAccountCode] = useState('1010');
  const [creditAccountCode, setCreditAccountCode] = useState('4010');
  const [costCenterId, setCostCenterId] = useState<string>('');
  const [debitPartyId, setDebitPartyId] = useState<string>('');
  const [creditPartyId, setCreditPartyId] = useState<string>('');

  const [currencyCode, setCurrencyCode] = useState<string>('');
  const [fxRate, setFxRate] = useState<string>('');
  const [foreignAmount, setForeignAmount] = useState<string>('');
  const [fxSource, setFxSource] = useState<'system' | 'manual' | 'unknown'>('unknown');

  const [busy, setBusy] = useState(false);
  const [lastEntryId, setLastEntryId] = useState<string>('');
  const [lastEntryStatus, setLastEntryStatus] = useState<string>('');
  const [lastEntryCreatedBy, setLastEntryCreatedBy] = useState<string>('');

  // History list state
  const [history, setHistory] = useState<VoucherHistoryRow[]>([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyFilter, setHistoryFilter] = useState<'all' | 'draft' | 'posted' | 'voided'>('all');
  const [historyTypeFilter, setHistoryTypeFilter] = useState<'all' | 'receipt' | 'payment' | 'journal'>('all');

  useEffect(() => {
    const supabase = getSupabaseClient();
    if (!supabase) return;
    if (!canView) {
      setAccounts([]);
      setCostCenters([]);
      setParties([]);
      setLoading(false);
      return;
    }
    void (async () => {
      setLoading(true);
      try {
        const [{ data: acc }, { data: cc }, { data: ps }, { data: cur }] = await Promise.all([
          supabase.from('chart_of_accounts').select('id,code,name').eq('is_active', true).order('code', { ascending: true }).limit(1500),
          supabase.from('cost_centers').select('id,name,code').eq('is_active', true).order('name', { ascending: true }).limit(500),
          supabase.from('financial_parties').select('id,name').eq('is_active', true).order('created_at', { ascending: false }).limit(500),
          supabase.from('currencies').select('code').order('code', { ascending: true }).limit(500),
        ]);
        setAccounts((Array.isArray(acc) ? acc : []).map((r: any) => ({
          id: String(r.id),
          code: String(r.code || ''),
          name: String(r.name || ''),
          nameAr: translateAccountName(String(r.name || ''))
        })));
        setCostCenters((Array.isArray(cc) ? cc : []).map((r: any) => ({ id: String(r.id), name: String(r.name || ''), code: r.code ? String(r.code) : null })));
        setParties((Array.isArray(ps) ? ps : []).map((r: any) => ({ id: String(r.id), name: String(r.name || '') })));
        setCurrencyOptions(
          (Array.isArray(cur) ? cur : [])
            .map((r: any) => String(r.code || '').trim().toUpperCase())
            .filter(Boolean),
        );
      } catch (e: any) {
        showNotification(String(e?.message || 'تعذر تحميل البيانات المساعدة.'), 'error');
      } finally {
        setLoading(false);
      }
    })();
  }, [canView, showNotification]);

  const normalizedCurrency = useMemo(() => String(currencyCode || '').trim().toUpperCase(), [currencyCode]);
  const usingForeign = Boolean(normalizedCurrency && normalizedCurrency !== baseCurrencyCode);
  const occurredAtYmd = useMemo(() => {
    const raw = String(occurredAt || '');
    if (raw.length >= 10) return raw.slice(0, 10);
    try {
      return new Date().toISOString().slice(0, 10);
    } catch {
      return '';
    }
  }, [occurredAt]);

  const applySystemFxRate = useCallback(async () => {
    const supabase = getSupabaseClient();
    if (!supabase) return;
    const code = String(normalizedCurrency || '').trim().toUpperCase();
    if (!code || !occurredAtYmd) return;
    if (code === baseCurrencyCode) {
      setFxRate('1');
      setFxSource('system');
      return;
    }
    try {
      const { data, error } = await supabase.rpc('get_fx_rate', {
        p_currency: code,
        p_date: occurredAtYmd,
        p_rate_type: 'operational',
      } as any);
      if (error) throw error;
      const n = Number(data);
      if (!Number.isFinite(n) || n <= 0) {
        setFxSource('unknown');
        showNotification('لا يوجد سعر صرف تشغيلي لهذه العملة في هذا التاريخ. أضف السعر من شاشة أسعار الصرف.', 'error');
        return;
      }
      setFxRate(String(n));
      setFxSource('system');
    } catch {
      setFxSource('unknown');
      showNotification('تعذر جلب سعر الصرف من النظام.', 'error');
    }
  }, [baseCurrencyCode, normalizedCurrency, occurredAtYmd, showNotification]);

  useEffect(() => {
    if (!canView) return;
    if (!normalizedCurrency || normalizedCurrency === baseCurrencyCode) {
      if (fxRate) setFxRate('');
      if (foreignAmount) setForeignAmount('');
      if (fxSource !== 'unknown') setFxSource('unknown');
      return;
    }
    if (fxRate && Number(fxRate) > 0) return;
    void applySystemFxRate();
  }, [applySystemFxRate, baseCurrencyCode, canView, foreignAmount, fxRate, fxSource, normalizedCurrency]);

  const amountBase = useMemo(() => {
    const n = Number(amount || '');
    return Number.isFinite(n) ? n : 0;
  }, [amount]);

  const fx = useMemo(() => {
    const n = Number(fxRate || '');
    return Number.isFinite(n) && n > 0 ? n : 0;
  }, [fxRate]);

  const fAmt = useMemo(() => {
    const n = Number(foreignAmount || '');
    return Number.isFinite(n) && n > 0 ? n : 0;
  }, [foreignAmount]);

  const finalBaseAmount = useMemo(() => {
    if (usingForeign) return fx * fAmt;
    return amountBase;
  }, [amountBase, fAmt, fx, usingForeign]);

  const buildLines = () => {
    const base = Number(finalBaseAmount || 0);
    const cur = usingForeign ? normalizedCurrency : '';
    const payloadCommon: any = {
      costCenterId: costCenterId || null,
    };
    if (cur) {
      payloadCommon.currencyCode = cur;
      payloadCommon.foreignAmount = fAmt > 0 ? fAmt : null;
    }
    return [
      {
        accountCode: String(debitAccountCode || '').trim(),
        debit: base,
        credit: 0,
        memo: memo ? `DV: ${memo}` : null,
        partyId: debitPartyId || null,
        ...payloadCommon,
      },
      {
        accountCode: String(creditAccountCode || '').trim(),
        debit: 0,
        credit: base,
        memo: memo ? `CV: ${memo}` : null,
        partyId: creditPartyId || null,
        ...payloadCommon,
      },
    ];
  };

  const loadEntryMeta = async (entryId: string) => {
    const supabase = getSupabaseClient();
    if (!supabase) return;
    const { data, error } = await supabase.from('journal_entries').select('id,status,created_by').eq('id', entryId).maybeSingle();
    if (error) throw error;
    setLastEntryStatus(String((data as any)?.status || ''));
    setLastEntryCreatedBy(String((data as any)?.created_by || ''));
  };

  const createVoucher = async () => {
    if (!canManage) {
      showNotification('ليس لديك صلاحية إنشاء السندات.', 'error');
      return;
    }
    const debitCode = String(debitAccountCode || '').trim();
    const creditCode = String(creditAccountCode || '').trim();
    if (!debitCode || !creditCode) {
      showNotification('حدد حسابين صحيحين.', 'error');
      return;
    }
    if (debitCode === creditCode) {
      showNotification('لا يمكن أن يكون الحسابان نفسهما.', 'error');
      return;
    }
    if (!(finalBaseAmount > 0)) {
      showNotification('أدخل مبلغًا صحيحًا.', 'error');
      return;
    }
    if (usingForeign && (!(fx > 0) || !(fAmt > 0))) {
      showNotification('تعذر اعتماد مبلغ أجنبي بدون سعر صرف من النظام ومبلغ أجنبي صحيح.', 'error');
      return;
    }

    const supabase = getSupabaseClient();
    if (!supabase) return;
    setBusy(true);
    try {
      const entryDateIso = occurredAt ? new Date(occurredAt).toISOString() : new Date().toISOString();
      const { data, error } = await supabase.rpc('create_manual_voucher', {
        p_voucher_type: voucherType,
        p_entry_date: entryDateIso,
        p_memo: memo || null,
        p_lines: buildLines() as any,
        p_journal_id: null,
      } as any);
      if (error) throw error;
      const entryId = String(data || '');
      setLastEntryId(entryId);
      await loadEntryMeta(entryId);
      showNotification(`تم إنشاء ${voucherTypeLabel} (مسودة).`, 'success');
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر إنشاء السند.'), 'error');
    } finally {
      setBusy(false);
    }
  };

  const fetchHistory = useCallback(async () => {
    const supabase = getSupabaseClient();
    if (!supabase || !canView) return;
    setHistoryLoading(true);
    try {
      let query = supabase
        .from('journal_entries')
        .select('id,entry_date,memo,status,source_event,document_id,created_by,journal_lines(line_memo)')
        .eq('source_table', 'manual')
        .order('entry_date', { ascending: false })
        .limit(50);
      if (historyFilter !== 'all') query = query.eq('status', historyFilter);
      if (historyTypeFilter !== 'all') query = query.eq('source_event', historyTypeFilter);
      const { data: rows, error } = await query;
      if (error) throw error;
      const mapped: VoucherHistoryRow[] = (rows || []).map((r: any) => {
        return {
          id: String(r.id || ''),
          entryDate: String(r.entry_date || ''),
          memo: (() => {
            const rawMemo = String(r.memo || '').trim();
            if (rawMemo && !rawMemo.match(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/i)) return rawMemo; // return if valid text not UUID

            const lines = Array.isArray(r.journal_lines) ? r.journal_lines : [];
            for (const l of lines) {
              const lm = String(l.line_memo || '').trim();
              if (lm && !lm.startsWith('CV: ') && !lm.startsWith('DV: ')) return lm.replace(/^[CD]V:\s*/i, '');
            }
            // fallback
            for (const l of lines) {
              const lm = String(l.line_memo || '').trim();
              if (lm) return lm.replace(/^[CD]V:\s*/i, '');
            }
            return 'بدون بيان';
          })(),
          status: String(r.status || ''),
          sourceEvent: String(r.source_event || ''),
          documentNumber: '',
          totalDebit: 0,
          createdBy: String(r.created_by || ''),
        };
      });
      setHistory(mapped);
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر تحميل سجل السندات.'), 'error');
    } finally {
      setHistoryLoading(false);
    }
  }, [canView, historyFilter, historyTypeFilter, showNotification]);

  useEffect(() => { void fetchHistory(); }, [fetchHistory]);

  const printHistoryEntry = async (entryId: string, type: string) => {
    try {
      const brand = {
        name: String((settings as any)?.cafeteriaName?.ar || (settings as any)?.cafeteriaName?.en || '').trim(),
        address: String((settings as any)?.address || '').trim(),
        contactNumber: String((settings as any)?.contactNumber || '').trim(),
        logoUrl: String((settings as any)?.logoUrl || '').trim(),
      };
      if (type === 'receipt') await printReceiptVoucherByEntryId(entryId, brand);
      else if (type === 'payment') await printPaymentVoucherByEntryId(entryId, brand);
      else await printJournalVoucherByEntryId(entryId, brand);
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر الطباعة.'), 'error');
    }
  };

  const approveHistoryEntry = async (entryId: string) => {
    if (!canApprove) { showNotification('ليس لديك صلاحية اعتماد السندات.', 'error'); return; }
    const supabase = getSupabaseClient();
    if (!supabase) return;
    try {
      const { error } = await supabase.rpc('approve_journal_entry', { p_entry_id: entryId } as any);
      if (error) throw error;
      showNotification('تم اعتماد السند.', 'success');
      void fetchHistory();
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر اعتماد السند.'), 'error');
    }
  };

  const voidHistoryEntry = async (entryId: string) => {
    if (!canVoid) { showNotification('ليس لديك صلاحية إبطال السندات.', 'error'); return; }
    const reason = window.prompt('سبب الإبطال/العكس؟') || '';
    if (!reason.trim()) return;
    const supabase = getSupabaseClient();
    if (!supabase) return;
    try {
      const { error } = await supabase.rpc('void_journal_entry', { p_entry_id: entryId, p_reason: reason.trim() } as any);
      if (error) throw error;
      showNotification('تم إبطال/عكس السند.', 'success');
      void fetchHistory();
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر إبطال/عكس السند.'), 'error');
    }
  };

  const eventLabel = (e: string) => {
    if (e === 'receipt') return 'قبض';
    if (e === 'payment') return 'صرف';
    if (e === 'journal') return 'قيد';
    return e;
  };
  const statusLabel = (s: string) => {
    if (s === 'draft') return 'مسودة';
    if (s === 'posted') return 'مُرحّل';
    if (s === 'voided') return 'مبطل';
    return s;
  };
  const statusColor = (s: string) => {
    if (s === 'draft') return 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-200';
    if (s === 'posted') return 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-200';
    if (s === 'voided') return 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-200';
    return 'bg-gray-100 text-gray-800';
  };

  const approveLast = async () => {
    if (!lastEntryId) return;
    if (!canApprove) {
      showNotification('ليس لديك صلاحية اعتماد السندات.', 'error');
      return;
    }
    if (userId && lastEntryCreatedBy && userId === lastEntryCreatedBy) {
      showNotification('لا يمكن اعتماد سند أنشأته أنت.', 'error');
      return;
    }
    const supabase = getSupabaseClient();
    if (!supabase) return;
    setBusy(true);
    try {
      const { error } = await supabase.rpc('approve_journal_entry', { p_entry_id: lastEntryId } as any);
      if (error) throw error;
      await loadEntryMeta(lastEntryId);
      showNotification('تم اعتماد السند.', 'success');
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر اعتماد السند.'), 'error');
    } finally {
      setBusy(false);
    }
  };

  const cancelDraftLast = async () => {
    if (!lastEntryId) return;
    if (!canManage) {
      showNotification('ليس لديك صلاحية إلغاء المسودات.', 'error');
      return;
    }
    const ok = window.confirm('إلغاء مسودة السند؟');
    if (!ok) return;
    const supabase = getSupabaseClient();
    if (!supabase) return;
    setBusy(true);
    try {
      const { error } = await supabase.rpc('cancel_manual_journal_draft', { p_entry_id: lastEntryId, p_reason: 'إلغاء سند' } as any);
      if (error) throw error;
      await loadEntryMeta(lastEntryId);
      showNotification('تم إلغاء المسودة.', 'success');
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر إلغاء المسودة.'), 'error');
    } finally {
      setBusy(false);
    }
  };

  const voidLast = async () => {
    if (!lastEntryId) return;
    if (!canVoid) {
      showNotification('ليس لديك صلاحية إبطال/عكس السندات.', 'error');
      return;
    }
    const reason = window.prompt('سبب الإبطال/العكس؟') || '';
    if (!reason.trim()) return;
    const supabase = getSupabaseClient();
    if (!supabase) return;
    setBusy(true);
    try {
      const { error } = await supabase.rpc('void_journal_entry', { p_entry_id: lastEntryId, p_reason: reason.trim() } as any);
      if (error) throw error;
      await loadEntryMeta(lastEntryId);
      showNotification('تم إبطال/عكس السند.', 'success');
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر إبطال/عكس السند.'), 'error');
    } finally {
      setBusy(false);
    }
  };

  const printLast = async () => {
    if (!lastEntryId) return;
    try {
      const brand = {
        name: String((settings as any)?.cafeteriaName?.ar || (settings as any)?.cafeteriaName?.en || '').trim(),
        address: String((settings as any)?.address || '').trim(),
        contactNumber: String((settings as any)?.contactNumber || '').trim(),
        logoUrl: String((settings as any)?.logoUrl || '').trim(),
      };
      if (voucherType === 'receipt') {
        await printReceiptVoucherByEntryId(lastEntryId, brand);
      } else if (voucherType === 'journal') {
        await printJournalVoucherByEntryId(lastEntryId, brand);
      } else {
        await printPaymentVoucherByEntryId(lastEntryId, brand);
      }
    } catch (e: any) {
      showNotification(String(e?.message || 'تعذر الطباعة.'), 'error');
    }
  };

  const voucherTypeLabel = useMemo(() => {
    if (voucherType === 'receipt') return 'سند قبض';
    if (voucherType === 'payment') return 'سند صرف';
    return 'سند قيد يومية';
  }, [voucherType]);
  const fxSourceLabel = useMemo(() => {
    if (fxSource === 'system') return 'سعر النظام';
    if (fxSource === 'manual') return 'يدوي';
    return 'غير محدد';
  }, [fxSource]);
  const screenTitle = useMemo(() => 'سندات (قبض / صرف / قيد يومية)', []);
  const screenSubtitle = useMemo(
    () => 'إنشاء سند يدوي من أي حساب إلى أي حساب كمسودة ثم اعتماد.',
    [],
  );

  if (!canView) {
    return <div className="p-8 text-center text-gray-500">لا تملك صلاحية عرض السندات.</div>;
  }

  return (
    <div className="p-6 max-w-5xl mx-auto space-y-4">
      <div>
        <h1 className="text-2xl font-bold dark:text-white">{screenTitle}</h1>
        <div className="text-sm text-gray-500 dark:text-gray-400">{screenSubtitle}</div>
      </div>

      {loading ? <div className="text-xs text-gray-500 dark:text-gray-400">جاري التحميل...</div> : null}

      {!canManage ? (
        <div className="bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg p-3 text-sm text-amber-900 dark:text-amber-200">
          وضع عرض فقط: تحتاج صلاحية accounting.manage لإنشاء السندات.
        </div>
      ) : null}

      {/* Removed datalist */}

      <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4 space-y-4">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
          <div>
            <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">نوع السند</div>
            <select value={voucherType} onChange={(e) => setVoucherType(e.target.value as any)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
              <option value="receipt">سند قبض</option>
              <option value="payment">سند صرف</option>
              <option value="journal">سند قيد يومية</option>
            </select>
          </div>
          <div>
            <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">التاريخ</div>
            <input type="datetime-local" value={occurredAt} onChange={(e) => setOccurredAt(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono" />
          </div>
          <div>
            <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">مركز تكلفة (اختياري)</div>
            <select value={costCenterId} onChange={(e) => setCostCenterId(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
              <option value="">—</option>
              {costCenters.map((c) => (
                <option key={c.id} value={c.id}>{c.name}{c.code ? ` (${c.code})` : ''}</option>
              ))}
            </select>
          </div>
        </div>

        <div>
          <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">البيان (اختياري)</div>
          <input value={memo} onChange={(e) => setMemo(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900" />
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
          <div>
            <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">المبلغ (بالعملة الأساسية)</div>
            <input
              type="number"
              value={usingForeign ? (finalBaseAmount > 0 ? String(finalBaseAmount.toFixed(2)) : '') : amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder={baseCurrencyCode}
              disabled={usingForeign}
              className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono disabled:opacity-60"
            />
            {usingForeign && fx > 0 && fAmt > 0 ? (
              <div className="text-[11px] text-gray-500 dark:text-gray-400 mt-1 font-mono" dir="ltr">
                محسوب: {(fx * fAmt).toFixed(2)} {baseCurrencyCode}
              </div>
            ) : null}
          </div>
          <div>
            <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">العملة (اختياري)</div>
            <select
              value={currencyCode}
              onChange={(e) => {
                setCurrencyCode(e.target.value);
                setFxRate('');
                setForeignAmount('');
                setFxSource('unknown');
              }}
              className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono"
            >
              <option value="">{baseCurrencyCode}</option>
              {currencyOptions
                .filter((c) => c !== baseCurrencyCode)
                .map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
            </select>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <div className="flex items-center justify-between gap-2 mb-1">
                <div className="text-xs text-gray-500 dark:text-gray-400">سعر الصرف{usingForeign ? ` (${fxSourceLabel})` : ''}</div>
                {usingForeign ? (
                  <button
                    type="button"
                    onClick={() => void applySystemFxRate()}
                    className="text-xs px-2 py-1 rounded-md border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900"
                  >
                    سعر النظام
                  </button>
                ) : null}
              </div>
              <input
                type="number"
                value={usingForeign ? fxRate : '1'}
                readOnly
                disabled={!usingForeign}
                className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono disabled:opacity-60"
              />
            </div>
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">مبلغ أجنبي</div>
              <input type="number" value={foreignAmount} onChange={(e) => setForeignAmount(e.target.value)} disabled={!usingForeign} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono disabled:opacity-60" />
            </div>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div className="bg-gray-50 dark:bg-gray-900/40 rounded-lg p-3 border border-gray-100 dark:border-gray-700 space-y-2">
            <div className="font-semibold dark:text-white">الطرف المدين</div>
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">حساب الأستاذ العام</div>
              <select value={debitAccountCode} onChange={(e) => setDebitAccountCode(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono text-sm">
                <option value="">— اختر החساب —</option>
                {accounts.map((a) => (
                  <option key={a.id} value={a.code}>{a.code} — {a.nameAr} {a.nameAr !== a.name ? `(${a.name})` : ''}</option>
                ))}
              </select>
            </div>
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">اسم الجهة/العميل (اختياري)</div>
              <select value={debitPartyId} onChange={(e) => setDebitPartyId(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
                <option value="">—</option>
                {parties.map((p) => (
                  <option key={p.id} value={p.id}>{p.name} — {p.id.slice(-6)}</option>
                ))}
              </select>
            </div>
          </div>

          <div className="bg-gray-50 dark:bg-gray-900/40 rounded-lg p-3 border border-gray-100 dark:border-gray-700 space-y-2">
            <div className="font-semibold dark:text-white">الطرف الدائن</div>
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">حساب الأستاذ العام</div>
              <select value={creditAccountCode} onChange={(e) => setCreditAccountCode(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono text-sm">
                <option value="">— اختر החساب —</option>
                {accounts.map((a) => (
                  <option key={a.id} value={a.code}>{a.code} — {a.nameAr} {a.nameAr !== a.name ? `(${a.name})` : ''}</option>
                ))}
              </select>
            </div>
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">اسم الجهة/العميل (اختياري)</div>
              <select value={creditPartyId} onChange={(e) => setCreditPartyId(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
                <option value="">—</option>
                {parties.map((p) => (
                  <option key={p.id} value={p.id}>{p.name} — {p.id.slice(-6)}</option>
                ))}
              </select>
            </div>
          </div>
        </div>

        <div className="flex items-center justify-end gap-2">
          <button type="button" onClick={() => void createVoucher()} disabled={busy || !canManage} className="px-4 py-2 rounded-lg bg-emerald-600 text-white font-semibold disabled:opacity-60">
            {busy ? 'جارٍ التنفيذ...' : 'إنشاء سند (مسودة)'}
          </button>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4">
        <div className="flex items-center justify-between gap-3">
          <div className="text-sm text-gray-700 dark:text-gray-200">
            آخر سند: <span className="font-mono" dir="ltr">{lastEntryId ? lastEntryId.slice(-8) : '—'}</span>
            {lastEntryStatus ? <span className="text-xs text-gray-500 dark:text-gray-400"> · {lastEntryStatus}</span> : null}
          </div>
          <div className="flex items-center gap-2">
            <button type="button" onClick={() => void printLast()} disabled={!lastEntryId} className="px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm disabled:opacity-60">
              طباعة
            </button>
            <button type="button" onClick={() => void approveLast()} disabled={!lastEntryId || busy || !canApprove} className="px-3 py-2 rounded-lg bg-green-600 text-white text-sm font-semibold disabled:opacity-60">
              اعتماد
            </button>
            <button type="button" onClick={() => void cancelDraftLast()} disabled={!lastEntryId || busy || !canManage} className="px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm disabled:opacity-60">
              إلغاء مسودة
            </button>
            <button type="button" onClick={() => void voidLast()} disabled={!lastEntryId || busy || !canVoid} className="px-3 py-2 rounded-lg bg-red-600 text-white text-sm font-semibold disabled:opacity-60">
              إبطال/عكس
            </button>
          </div>
        </div>
      </div>

      {/* Voucher History */}
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-4 space-y-3">
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-lg font-bold dark:text-white">سجل السندات</h2>
          <button type="button" onClick={() => void fetchHistory()} disabled={historyLoading} className="px-3 py-1.5 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm disabled:opacity-60">
            {historyLoading ? 'جارٍ...' : 'تحديث'}
          </button>
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          <select value={historyFilter} onChange={(e) => setHistoryFilter(e.target.value as any)} className="px-3 py-1.5 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm">
            <option value="all">كل الحالات</option>
            <option value="draft">مسودة</option>
            <option value="posted">مُرحّل</option>
            <option value="voided">مبطل</option>
          </select>
          <select value={historyTypeFilter} onChange={(e) => setHistoryTypeFilter(e.target.value as any)} className="px-3 py-1.5 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm">
            <option value="all">كل الأنواع</option>
            <option value="receipt">سند قبض</option>
            <option value="payment">سند صرف</option>
            <option value="journal">قيد يومية</option>
          </select>
        </div>
        {historyLoading ? (
          <div className="text-xs text-gray-500 dark:text-gray-400 py-4 text-center">جاري تحميل السجل...</div>
        ) : history.length === 0 ? (
          <div className="text-sm text-gray-500 dark:text-gray-400 py-4 text-center">لا توجد سندات مسجلة.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b dark:border-gray-700 text-center">
                  <th className="py-2 px-2 font-semibold text-gray-600 dark:text-gray-300">المعرف</th>
                  <th className="py-2 px-2 font-semibold text-gray-600 dark:text-gray-300">النوع</th>
                  <th className="py-2 px-2 font-semibold text-gray-600 dark:text-gray-300">التاريخ</th>
                  <th className="py-2 px-2 font-semibold text-gray-600 dark:text-gray-300">البيان</th>
                  <th className="py-2 px-2 font-semibold text-gray-600 dark:text-gray-300">الحالة</th>
                  <th className="py-2 px-2 font-semibold text-gray-600 dark:text-gray-300">عمليات</th>
                </tr>
              </thead>
              <tbody>
                {history.map((h) => (
                  <tr key={h.id} className="border-b dark:border-gray-700/50 hover:bg-gray-50 dark:hover:bg-gray-700/30 text-center">
                    <td className="py-2 px-2 font-mono text-xs" dir="ltr">{h.id.slice(-8)}</td>
                    <td className="py-2 px-2">
                      <span className={`px-2 py-0.5 rounded-full text-xs font-semibold ${h.sourceEvent === 'receipt' ? 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-200'
                        : h.sourceEvent === 'payment' ? 'bg-orange-100 text-orange-800 dark:bg-orange-900/30 dark:text-orange-200'
                          : 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-200'
                        }`}>{eventLabel(h.sourceEvent)}</span>
                    </td>
                    <td className="py-2 px-2 font-mono text-xs" dir="ltr">
                      {(() => {
                        try {
                          const d = new Date(h.entryDate);
                          return `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getDate()).padStart(2, '0')}`;
                        } catch { return h.entryDate; }
                      })()}
                    </td>
                    <td className="py-2 px-2 text-gray-700 dark:text-gray-300 max-w-[200px] truncate">{h.memo && h.memo.length > 3 ? h.memo : '—'}</td>
                    <td className="py-2 px-2">
                      <span className={`px-2 py-0.5 rounded-full text-xs font-semibold ${statusColor(h.status)}`}>{statusLabel(h.status)}</span>
                    </td>
                    <td className="py-2 px-2">
                      <div className="flex items-center justify-center gap-1">
                        <button type="button" onClick={() => void printHistoryEntry(h.id, h.sourceEvent)} className="px-2 py-1 rounded text-xs border border-gray-200 dark:border-gray-600 hover:bg-gray-100 dark:hover:bg-gray-700">
                          طباعة
                        </button>
                        {h.status === 'draft' && canApprove ? (
                          <button type="button" onClick={() => void approveHistoryEntry(h.id)} className="px-2 py-1 rounded text-xs bg-green-600 text-white hover:bg-green-700">
                            اعتماد
                          </button>
                        ) : null}
                        {(h.status === 'draft' || h.status === 'posted') && canVoid ? (
                          <button type="button" onClick={() => void voidHistoryEntry(h.id)} className="px-2 py-1 rounded text-xs bg-red-600 text-white hover:bg-red-700">
                            إبطال
                          </button>
                        ) : null}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
