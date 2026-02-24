import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { getBaseCurrencyCode, getSupabaseClient } from '../../supabase';
import * as Icons from '../../components/icons';
import { useAuth } from '../../contexts/AuthContext';
import { useToast } from '../../contexts/ToastContext';

type PartyRow = { id: string; name: string };

type DocRow = {
  id: string;
  doc_type: string;
  doc_number: string;
  occurred_at: string;
  memo: string | null;
  party_id: string;
  status: string;
  journal_entry_id: string | null;
};

type DocType =
  | 'ar_invoice' | 'ap_bill'
  | 'ar_receipt' | 'ap_payment'
  | 'ar_credit_note' | 'ap_credit_note'
  | 'ar_debit_note' | 'ap_debit_note'
  | 'advance' | 'custodian';

const docTypeLabel: Record<DocType, string> = {
  ar_invoice: 'فاتورة عميل (AR)',
  ap_bill: 'فاتورة مورد (AP)',
  ar_receipt: 'سند قبض (AR)',
  ap_payment: 'سند صرف (AP)',
  ar_credit_note: 'إشعار دائن عميل (AR CN)',
  ap_credit_note: 'إشعار دائن مورد (AP CN)',
  ar_debit_note: 'إشعار مدين عميل (AR DN)',
  ap_debit_note: 'إشعار مدين مورد (AP DN)',
  advance: 'دفعة مقدمة',
  custodian: 'عهدة',
};

const defaultAccounts: Record<DocType, { partyAccount: string; counterAccount: string; cashAccount?: string }> = {
  ar_invoice: { partyAccount: '1200', counterAccount: '4010' },
  ap_bill: { partyAccount: '2010', counterAccount: '6100' },
  ar_receipt: { partyAccount: '1200', counterAccount: '1010', cashAccount: '1010' },
  ap_payment: { partyAccount: '2010', counterAccount: '1010', cashAccount: '1010' },
  ar_credit_note: { partyAccount: '1200', counterAccount: '4010' },
  ap_credit_note: { partyAccount: '2010', counterAccount: '6100' },
  ar_debit_note: { partyAccount: '1200', counterAccount: '4010' },
  ap_debit_note: { partyAccount: '2010', counterAccount: '6100' },
  advance: { partyAccount: '1350', counterAccount: '1010', cashAccount: '1010' },
  custodian: { partyAccount: '1035', counterAccount: '1010', cashAccount: '1010' },
};

export default function PartyDocumentsScreen() {
  const { showNotification } = useToast();
  const { hasPermission } = useAuth();
  const canManage = hasPermission('accounting.manage');
  const canApprove = hasPermission('accounting.approve');
  const canView = hasPermission('accounting.view');
  const [baseCurrencyCode, setBaseCurrencyCode] = useState('YER');
  const [currencyOptions, setCurrencyOptions] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [partyMap, setPartyMap] = useState<Record<string, string>>({});
  const [q, setQ] = useState('');
  const [statusFilter, setStatusFilter] = useState<'all' | 'draft' | 'posted' | 'voided'>('all');

  const [parties, setParties] = useState<PartyRow[]>([]);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [docType, setDocType] = useState<DocType>('ar_invoice');
  const [partyId, setPartyId] = useState('');
  const [occurredAt, setOccurredAt] = useState(() => new Date().toISOString().slice(0, 16));
  const [memo, setMemo] = useState('');
  const [amount, setAmount] = useState<number>(0);
  const [partyAccountCode, setPartyAccountCode] = useState(defaultAccounts.ar_invoice.partyAccount);
  const [counterAccountCode, setCounterAccountCode] = useState(defaultAccounts.ar_invoice.counterAccount);
  const [currencyCode, setCurrencyCode] = useState('');
  const [fxRate, setFxRate] = useState<string>('');
  const [foreignAmount, setForeignAmount] = useState<string>('');
  const [fxSource, setFxSource] = useState<'system' | 'unknown'>('unknown');

  const load = async () => {
    setLoading(true);
    try {
      const supabase = getSupabaseClient();
      if (!supabase) throw new Error('supabase not available');

      const { data, error } = await supabase
        .from('party_documents')
        .select('id,doc_type,doc_number,occurred_at,memo,party_id,status,journal_entry_id')
        .order('occurred_at', { ascending: false })
        .limit(500);
      if (error) throw error;
      const rows = (Array.isArray(data) ? data : []) as any as DocRow[];
      setDocs(rows);

      const ids = Array.from(new Set(rows.map((r) => String(r.party_id || '')).filter(Boolean)));
      if (ids.length > 0) {
        const { data: pData } = await supabase.from('financial_parties').select('id,name').in('id', ids);
        const map: Record<string, string> = {};
        (Array.isArray(pData) ? pData : []).forEach((r: any) => {
          map[String(r.id)] = String(r.name || '—');
        });
        setPartyMap(map);
      } else {
        setPartyMap({});
      }
    } finally {
      setLoading(false);
    }
  };

  const loadParties = async () => {
    const supabase = getSupabaseClient();
    if (!supabase) return;
    const { data } = await supabase.from('financial_parties').select('id,name').eq('is_active', true).order('created_at', { ascending: false }).limit(500);
    const rows = (Array.isArray(data) ? data : []).map((r: any) => ({ id: String(r.id), name: String(r.name || '—') }));
    setParties(rows);
    if (!partyId && rows.length > 0) setPartyId(rows[0].id);
  };

  useEffect(() => {
    void load();
    void loadParties();
  }, []);

  useEffect(() => {
    void getBaseCurrencyCode().then((c) => {
      if (!c) return;
      setBaseCurrencyCode(String(c).trim().toUpperCase());
    });
  }, []);

  useEffect(() => {
    let active = true;
    const loadCurrencies = async () => {
      try {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        const { data, error } = await supabase.from('currencies').select('code').order('code', { ascending: true }).limit(500);
        if (error) throw error;
        const codes = (Array.isArray(data) ? data : []).map((r: any) => String(r.code || '').trim().toUpperCase()).filter(Boolean);
        if (active) setCurrencyOptions(codes);
      } catch {
        if (active) setCurrencyOptions([]);
      }
    };
    void loadCurrencies();
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    setPartyAccountCode(defaultAccounts[docType].partyAccount);
    setCounterAccountCode(defaultAccounts[docType].counterAccount);
  }, [docType]);

  const normalizedCurrency = useMemo(() => String(currencyCode || '').trim().toUpperCase(), [currencyCode]);
  const usingForeign = useMemo(() => Boolean(normalizedCurrency && normalizedCurrency !== baseCurrencyCode), [baseCurrencyCode, normalizedCurrency]);
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
    if (!normalizedCurrency || !occurredAtYmd) return;
    if (normalizedCurrency === baseCurrencyCode) {
      setFxRate('1');
      setFxSource('system');
      return;
    }
    try {
      const { data, error } = await supabase.rpc('get_fx_rate', {
        p_currency: normalizedCurrency,
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
    if (!normalizedCurrency || normalizedCurrency === baseCurrencyCode) {
      if (fxRate) setFxRate('');
      if (foreignAmount) setForeignAmount('');
      if (fxSource !== 'unknown') setFxSource('unknown');
      return;
    }
    if (fxRate && Number(fxRate) > 0) return;
    void applySystemFxRate();
  }, [applySystemFxRate, baseCurrencyCode, foreignAmount, fxRate, fxSource, normalizedCurrency]);

  const fx = useMemo(() => {
    const n = Number(fxRate || '');
    return Number.isFinite(n) && n > 0 ? n : 0;
  }, [fxRate]);

  const fAmt = useMemo(() => {
    const n = Number(foreignAmount || '');
    return Number.isFinite(n) && n > 0 ? n : 0;
  }, [foreignAmount]);

  const baseFromForeign = useMemo(() => (usingForeign ? fx * fAmt : 0), [fAmt, fx, usingForeign]);

  const filtered = useMemo(() => {
    const needle = String(q || '').trim().toLowerCase();
    return docs.filter((d) => {
      if (statusFilter !== 'all' && String(d.status || '') !== statusFilter) return false;
      if (!needle) return true;
      const hay = [
        d.doc_number,
        d.doc_type,
        d.status,
        d.memo || '',
        partyMap[d.party_id] || '',
        d.party_id,
        d.journal_entry_id || '',
      ].join(' | ').toLowerCase();
      return hay.includes(needle);
    });
  }, [docs, q, statusFilter, partyMap]);

  const openCreate = () => {
    setDocType('ar_invoice');
    setMemo('');
    setAmount(0);
    setCurrencyCode('');
    setFxRate('');
    setForeignAmount('');
    setFxSource('unknown');
    setOccurredAt(new Date().toISOString().slice(0, 16));
    setIsModalOpen(true);
  };

  const buildLines = () => {
    const cur = normalizedCurrency;
    const baseAmt = usingForeign ? baseFromForeign : Number(amount || 0);
    if (!(baseAmt > 0)) throw new Error('المبلغ يجب أن يكون أكبر من صفر');
    if (usingForeign && (!(fx > 0) || !(fAmt > 0))) throw new Error('تعذر اعتماد مبلغ أجنبي بدون سعر صرف من النظام ومبلغ أجنبي صحيح');

    const partyLine: any = {
      accountCode: partyAccountCode,
      debit: 0,
      credit: 0,
      memo: memo ? `Party: ${memo}` : null,
      partyId,
    };
    const counterLine: any = {
      accountCode: counterAccountCode,
      debit: 0,
      credit: 0,
      memo: memo ? `Counter: ${memo}` : null,
    };

    if (docType === 'ar_invoice') {
      partyLine.debit = baseAmt;
      counterLine.credit = baseAmt;
    } else if (docType === 'ap_bill') {
      counterLine.debit = baseAmt;
      partyLine.credit = baseAmt;
    } else if (docType === 'ar_receipt') {
      counterLine.debit = baseAmt;
      partyLine.credit = baseAmt;
    } else if (docType === 'ap_payment') {
      partyLine.debit = baseAmt;
      counterLine.credit = baseAmt;
    } else if (docType === 'ar_credit_note') {
      partyLine.credit = baseAmt;
      counterLine.debit = baseAmt;
    } else if (docType === 'ap_credit_note') {
      counterLine.credit = baseAmt;
      partyLine.debit = baseAmt;
    } else if (docType === 'ar_debit_note') {
      partyLine.debit = baseAmt;
      counterLine.credit = baseAmt;
    } else if (docType === 'ap_debit_note') {
      counterLine.debit = baseAmt;
      partyLine.credit = baseAmt;
    } else if (docType === 'advance') {
      partyLine.debit = baseAmt;
      counterLine.credit = baseAmt;
    } else if (docType === 'custodian') {
      partyLine.debit = baseAmt;
      counterLine.credit = baseAmt;
    }

    if (usingForeign) {
      partyLine.currencyCode = cur;
      partyLine.fxRate = fx;
      partyLine.foreignAmount = fAmt;
    }

    return [partyLine, counterLine];
  };

  const createDoc = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canManage) {
      showNotification('ليس لديك صلاحية لإنشاء المستندات.', 'error');
      return;
    }
    try {
      const supabase = getSupabaseClient();
      if (!supabase) return;
      const lines = buildLines();
      const occurred = new Date(occurredAt).toISOString();
      const { data, error } = await supabase.rpc('create_party_document', {
        p_doc_type: docType,
        p_occurred_at: occurred,
        p_party_id: partyId,
        p_memo: memo || null,
        p_lines: lines as any,
      } as any);
      if (error) throw error;
      if (!data) throw new Error('تعذر إنشاء المستند');
      setIsModalOpen(false);
      await load();
      showNotification('تم إنشاء المستند.', 'success');
    } catch (err: any) {
      showNotification(String(err?.message || 'فشل إنشاء المستند'), 'error');
    }
  };

  const approveDoc = async (id: string) => {
    if (!canApprove) {
      showNotification('ليس لديك صلاحية لاعتماد المستندات.', 'error');
      return;
    }
    if (!window.confirm('هل تريد اعتماد هذا المستند؟')) return;
    try {
      const supabase = getSupabaseClient();
      if (!supabase) return;
      const { error } = await supabase.rpc('approve_party_document', { p_document_id: id } as any);
      if (error) throw error;
      await load();
      showNotification('تم اعتماد المستند.', 'success');
    } catch (err: any) {
      showNotification(String(err?.message || 'فشل الاعتماد'), 'error');
    }
  };

  const voidDoc = async (id: string) => {
    if (!canManage) {
      showNotification('ليس لديك صلاحية لإبطال المستندات.', 'error');
      return;
    }
    const reason = window.prompt('سبب الإلغاء/الإبطال؟');
    if (!reason) return;
    try {
      const supabase = getSupabaseClient();
      if (!supabase) return;
      const { error } = await supabase.rpc('void_party_document', { p_document_id: id, p_reason: reason } as any);
      if (error) throw error;
      await load();
      showNotification('تم إبطال المستند.', 'success');
    } catch (err: any) {
      showNotification(String(err?.message || 'فشل الإبطال'), 'error');
    }
  };

  if (!canView) return <div className="p-8 text-center text-gray-500">لا تملك صلاحية عرض مستندات الأطراف.</div>;
  if (loading) return <div className="p-8 text-center text-gray-500">جاري التحميل...</div>;

  return (
    <div className="p-6 max-w-7xl mx-auto">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-3xl font-bold bg-clip-text text-transparent bg-gradient-to-l from-primary-600 to-gold-500">
          مستندات الأطراف
        </h1>
        {canManage && (
          <button
            onClick={openCreate}
            className="bg-primary-500 text-white px-4 py-2 rounded-lg flex items-center gap-2 hover:bg-primary-600 shadow-lg transition-transform transform hover:-translate-y-1"
          >
            <Icons.PlusIcon className="w-5 h-5" />
            <span>مستند جديد</span>
          </button>
        )}
      </div>

      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg border border-gray-100 dark:border-gray-700 p-4 mb-4 flex flex-col md:flex-row gap-2 items-stretch md:items-center">
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="بحث: رقم/نوع/طرف/حالة..."
          className="border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200"
        />
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value as any)}
          className="border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200"
        >
          <option value="all">كل الحالات</option>
          <option value="draft">مسودة</option>
          <option value="posted">معتمد</option>
          <option value="voided">مبطل</option>
        </select>
        <button
          onClick={() => void load()}
          className="bg-white dark:bg-gray-800 text-gray-800 dark:text-gray-200 px-3 py-2 rounded-lg flex items-center gap-2 hover:bg-gray-50 dark:hover:bg-gray-700 border border-gray-100 dark:border-gray-700"
        >
          <Icons.ReportIcon className="w-5 h-5" />
          <span>تحديث</span>
        </button>
      </div>

      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg border border-gray-100 dark:border-gray-700 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right min-w-[1100px]">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">التاريخ</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">النوع</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">رقم</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الطرف</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الحالة</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">القيد</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300">الإجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={7} className="p-8 text-center text-gray-500 dark:text-gray-400">
                    لا توجد بيانات.
                  </td>
                </tr>
              ) : (
                filtered.map((d) => (
                  <tr key={d.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/30 transition-colors">
                    <td className="p-4 text-gray-700 dark:text-gray-200 border-r dark:border-gray-700 font-mono" dir="ltr">
                      {new Date(d.occurred_at).toLocaleString('ar-SA-u-nu-latn')}
                    </td>
                    <td className="p-4 text-gray-700 dark:text-gray-200 border-r dark:border-gray-700">
                      {docTypeLabel[d.doc_type as DocType] || d.doc_type}
                    </td>
                    <td className="p-4 text-gray-700 dark:text-gray-200 border-r dark:border-gray-700 font-mono" dir="ltr">
                      {d.doc_number}
                    </td>
                    <td className="p-4 text-gray-700 dark:text-gray-200 border-r dark:border-gray-700">
                      <div className="font-medium">{partyMap[d.party_id] || '—'}</div>
                      <div className="text-xs text-gray-500 dark:text-gray-400 font-mono" dir="ltr">{d.party_id}</div>
                    </td>
                    <td className="p-4 border-r dark:border-gray-700">
                      <span className={`px-2 py-1 rounded-full text-xs ${d.status === 'posted' ? 'bg-green-100 text-green-800 dark:bg-green-900/20 dark:text-green-200' : d.status === 'draft' ? 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/20 dark:text-yellow-200' : 'bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-200'}`}>
                        {d.status === 'posted' ? 'معتمد' : d.status === 'draft' ? 'مسودة' : 'مبطل'}
                      </span>
                    </td>
                    <td className="p-4 text-gray-700 dark:text-gray-200 border-r dark:border-gray-700 font-mono" dir="ltr">
                      {d.journal_entry_id ? String(d.journal_entry_id).slice(-8) : '—'}
                    </td>
                    <td className="p-4 flex gap-2">
                      {d.status === 'draft' && canApprove && (
                        <button
                          onClick={() => void approveDoc(d.id)}
                          className="p-2 text-green-700 bg-green-50 dark:bg-green-900/20 rounded-lg hover:bg-green-100 dark:hover:bg-green-900/40 transition-colors"
                          title="اعتماد"
                        >
                          <Icons.CheckIcon className="w-4 h-4" />
                        </button>
                      )}
                      {d.status !== 'voided' && canManage && (
                        <button
                          onClick={() => void voidDoc(d.id)}
                          className="p-2 text-red-700 bg-red-50 dark:bg-red-900/20 rounded-lg hover:bg-red-100 dark:hover:bg-red-900/40 transition-colors"
                          title="إبطال"
                        >
                          <Icons.TrashIcon className="w-4 h-4" />
                        </button>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {isModalOpen && (
        <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-2xl border border-gray-200 dark:border-gray-700">
            <div className="flex justify-between items-center p-4 border-b border-gray-100 dark:border-gray-700">
              <h2 className="text-lg font-bold dark:text-white">مستند طرف جديد</h2>
              <button onClick={() => setIsModalOpen(false)} className="text-gray-500 hover:text-gray-700 dark:text-gray-300">
                <Icons.XIcon className="w-5 h-5" />
              </button>
            </div>
            <form onSubmit={createDoc} className="p-4 space-y-3">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">النوع</label>
                  <select
                    value={docType}
                    onChange={(e) => setDocType(e.target.value as DocType)}
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200"
                  >
                    {Object.entries(docTypeLabel).map(([k, v]) => (
                      <option key={k} value={k}>{v}</option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">التاريخ</label>
                  <input
                    type="datetime-local"
                    value={occurredAt}
                    onChange={(e) => setOccurredAt(e.target.value)}
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200 font-mono"
                  />
                </div>
              </div>

              <div>
                <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">الطرف</label>
                <select
                  value={partyId}
                  onChange={(e) => setPartyId(e.target.value)}
                  className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200"
                >
                  {parties.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name} — {p.id.slice(-6)}
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">المبلغ (عملة الأساس)</label>
                  <input
                    type="number"
                    value={usingForeign ? (baseFromForeign > 0 ? String(baseFromForeign.toFixed(2)) : '') : String(amount)}
                    onChange={(e) => setAmount(Number(e.target.value))}
                    disabled={usingForeign}
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200 font-mono"
                  />
                </div>
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">حساب الطرف</label>
                  <input
                    value={partyAccountCode}
                    onChange={(e) => setPartyAccountCode(e.target.value)}
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200 font-mono"
                  />
                </div>
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">الحساب المقابل</label>
                  <input
                    value={counterAccountCode}
                    onChange={(e) => setCounterAccountCode(e.target.value)}
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200 font-mono"
                  />
                </div>
              </div>

              <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">العملة (اختياري)</label>
                  <select
                    value={currencyCode}
                    onChange={(e) => {
                      setCurrencyCode(e.target.value);
                      setFxRate('');
                      setForeignAmount('');
                      setFxSource('unknown');
                    }}
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200 font-mono"
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
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">سعر الصرف (سعر النظام)</label>
                  <input
                    value={fxRate}
                    readOnly
                    disabled={!usingForeign}
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200 font-mono"
                  />
                </div>
                <div>
                  <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">المبلغ الأجنبي (اختياري)</label>
                  <input
                    value={foreignAmount}
                    onChange={(e) => setForeignAmount(e.target.value)}
                    placeholder="100"
                    className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200 font-mono"
                  />
                </div>
              </div>

              <div>
                <label className="block text-sm text-gray-600 dark:text-gray-300 mb-1">مذكرة</label>
                <input
                  value={memo}
                  onChange={(e) => setMemo(e.target.value)}
                  className="w-full border border-gray-200 dark:border-gray-700 rounded-lg px-3 py-2 bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-200"
                />
              </div>

              <div className="flex justify-end gap-2 pt-2">
                <button type="button" onClick={() => setIsModalOpen(false)} className="px-4 py-2 rounded-lg bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200">
                  إلغاء
                </button>
                <button type="submit" className="px-4 py-2 rounded-lg bg-primary-600 text-white hover:bg-primary-700">
                  إنشاء مسودة
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
