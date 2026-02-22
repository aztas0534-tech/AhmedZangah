import { useEffect, useMemo, useState } from 'react';
import { getSupabaseClient } from '../../supabase';
import { useAuth } from '../../contexts/AuthContext';
import { useToast } from '../../contexts/ToastContext';
import { useSettings } from '../../contexts/SettingsContext';
import { printJournalVoucherByEntryId, printPaymentVoucherByEntryId, printReceiptVoucherByEntryId } from '../../utils/vouchers';

type AccountRow = { id: string; code: string; name: string };
type CostCenterRow = { id: string; name: string; code: string | null };
type PartyRow = { id: string; name: string };

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

  const [busy, setBusy] = useState(false);
  const [lastEntryId, setLastEntryId] = useState<string>('');
  const [lastEntryStatus, setLastEntryStatus] = useState<string>('');
  const [lastEntryCreatedBy, setLastEntryCreatedBy] = useState<string>('');

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
        const [{ data: acc }, { data: cc }, { data: ps }] = await Promise.all([
          supabase.from('chart_of_accounts').select('id,code,name').eq('is_active', true).order('code', { ascending: true }).limit(1500),
          supabase.from('cost_centers').select('id,name,code').eq('is_active', true).order('name', { ascending: true }).limit(500),
          supabase.from('financial_parties').select('id,name').eq('is_active', true).order('created_at', { ascending: false }).limit(500),
        ]);
        setAccounts((Array.isArray(acc) ? acc : []).map((r: any) => ({ id: String(r.id), code: String(r.code || ''), name: String(r.name || '') })));
        setCostCenters((Array.isArray(cc) ? cc : []).map((r: any) => ({ id: String(r.id), name: String(r.name || ''), code: r.code ? String(r.code) : null })));
        setParties((Array.isArray(ps) ? ps : []).map((r: any) => ({ id: String(r.id), name: String(r.name || '') })));
      } catch (e: any) {
        showNotification(String(e?.message || 'تعذر تحميل البيانات المساعدة.'), 'error');
      } finally {
        setLoading(false);
      }
    })();
  }, [canView, showNotification]);

  const normalizedCurrency = useMemo(() => String(currencyCode || '').trim().toUpperCase(), [currencyCode]);
  const usingForeign = normalizedCurrency && normalizedCurrency !== baseCurrencyCode;

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
    if (usingForeign && fx > 0 && fAmt > 0) return fx * fAmt;
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
      payloadCommon.fxRate = fx > 0 ? fx : null;
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
      showNotification('أدخل مبلغًا أجنبيًا وسعر صرف صحيحين.', 'error');
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

  const accountOptionsId = useMemo(() => 'voucher-account-options', []);
  const voucherTypeLabel = useMemo(() => {
    if (voucherType === 'receipt') return 'سند قبض';
    if (voucherType === 'payment') return 'سند صرف';
    return 'سند قيد يومية';
  }, [voucherType]);
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

      <datalist id={accountOptionsId}>
        {accounts.map((a) => (
          <option key={a.id} value={a.code}>{a.name}</option>
        ))}
      </datalist>

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
            <input type="number" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder={baseCurrencyCode} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono" />
            {usingForeign && fx > 0 && fAmt > 0 ? (
              <div className="text-[11px] text-gray-500 dark:text-gray-400 mt-1 font-mono" dir="ltr">
                محسوب: {(fx * fAmt).toFixed(2)} {baseCurrencyCode}
              </div>
            ) : null}
          </div>
          <div>
            <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">العملة (اختياري)</div>
            <input value={currencyCode} onChange={(e) => setCurrencyCode(e.target.value)} placeholder={baseCurrencyCode} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono" />
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">سعر الصرف</div>
              <input type="number" value={fxRate} onChange={(e) => setFxRate(e.target.value)} disabled={!usingForeign} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono disabled:opacity-60" />
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
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الحساب (Debit)</div>
              <input list={accountOptionsId} value={debitAccountCode} onChange={(e) => setDebitAccountCode(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono" />
            </div>
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">طرف مالي (اختياري)</div>
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
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">الحساب (Credit)</div>
              <input list={accountOptionsId} value={creditAccountCode} onChange={(e) => setCreditAccountCode(e.target.value)} className="w-full px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 font-mono" />
            </div>
            <div>
              <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">طرف مالي (اختياري)</div>
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
    </div>
  );
}
