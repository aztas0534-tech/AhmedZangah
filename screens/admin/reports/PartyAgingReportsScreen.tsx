import React, { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { getSupabaseClient } from '../../../supabase';
import * as Icons from '../../../components/icons';

type AgingRow = {
  party_id: string;
  party_name: string;
  currency_code: string;
  current_amount: number;
  days_1_30: number;
  days_31_60: number;
  days_61_90: number;
  days_91_plus: number;
  total_outstanding: number;
};

type LegacyAgingRow = {
  party_id: string;
  current: number;
  days_1_30: number;
  days_31_60: number;
  days_61_90: number;
  days_91_plus: number;
  total_outstanding: number;
};

const PartyAgingReportsScreen: React.FC = () => {
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState<'ar' | 'ap'>('ar');
  const [currencyMode, setCurrencyMode] = useState<'all' | 'by_currency'>('by_currency');
  const [arByCurrency, setArByCurrency] = useState<AgingRow[]>([]);
  const [apByCurrency, setApByCurrency] = useState<AgingRow[]>([]);
  const [arLegacy, setArLegacy] = useState<LegacyAgingRow[]>([]);
  const [apLegacy, setApLegacy] = useState<LegacyAgingRow[]>([]);
  const [partyNames, setPartyNames] = useState<Record<string, string>>({});
  const [currencyFilter, setCurrencyFilter] = useState<string>('');

  const load = async () => {
    setLoading(true);
    try {
      const supabase = getSupabaseClient();
      if (!supabase) throw new Error('supabase not available');

      // Load both per-currency and legacy data
      const [
        { data: arCurData, error: arCurErr },
        { data: apCurData, error: apCurErr },
        { data: arLegData },
        { data: apLegData },
      ] = await Promise.all([
        supabase.rpc('party_ar_aging_by_currency', {} as any),
        supabase.rpc('party_ap_aging_by_currency', {} as any),
        supabase.from('party_ar_aging_summary').select('*'),
        supabase.from('party_ap_aging_summary').select('*'),
      ]);

      if (arCurErr) console.warn('party_ar_aging_by_currency error:', arCurErr);
      if (apCurErr) console.warn('party_ap_aging_by_currency error:', apCurErr);

      const arCurRows = (Array.isArray(arCurData) ? arCurData : []) as AgingRow[];
      const apCurRows = (Array.isArray(apCurData) ? apCurData : []) as AgingRow[];
      setArByCurrency(arCurRows);
      setApByCurrency(apCurRows);
      setArLegacy((Array.isArray(arLegData) ? arLegData : []) as LegacyAgingRow[]);
      setApLegacy((Array.isArray(apLegData) ? apLegData : []) as LegacyAgingRow[]);

      // Build party name map from per-currency data (which includes party_name)
      const map: Record<string, string> = {};
      [...arCurRows, ...apCurRows].forEach((r) => {
        if (r.party_id && r.party_name) map[r.party_id] = r.party_name;
      });

      // Also fetch from legacy rows
      const legacyIds = [...(Array.isArray(arLegData) ? arLegData : []), ...(Array.isArray(apLegData) ? apLegData : [])]
        .map((r: any) => String(r.party_id || ''))
        .filter(Boolean)
        .filter((id) => !map[id]);

      if (legacyIds.length > 0) {
        const uniqueIds = Array.from(new Set(legacyIds));
        const { data: pData } = await supabase.from('financial_parties').select('id,name').in('id', uniqueIds);
        (Array.isArray(pData) ? pData : []).forEach((r: any) => {
          map[String(r.id)] = String(r.name || '—');
        });
      }
      setPartyNames(map);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void load();
  }, []);

  const availableCurrencies = useMemo(() => {
    const rows = tab === 'ar' ? arByCurrency : apByCurrency;
    const codes = Array.from(new Set(rows.map((r) => r.currency_code).filter(Boolean)));
    return codes.sort();
  }, [tab, arByCurrency, apByCurrency]);

  const rows = useMemo(() => {
    if (currencyMode === 'by_currency') {
      const source = tab === 'ar' ? arByCurrency : apByCurrency;
      return source
        .filter((r) => !currencyFilter || r.currency_code === currencyFilter)
        .slice()
        .sort((a, b) => (Number(b.total_outstanding) || 0) - (Number(a.total_outstanding) || 0));
    }

    // Legacy mode — base currency aggregated
    const source = tab === 'ar' ? arLegacy : apLegacy;
    return source
      .map((r) => ({
        ...r,
        party_name: partyNames[r.party_id] || '—',
        currency_code: '',
        current_amount: r.current,
      }))
      .sort((a, b) => (Number(b.total_outstanding) || 0) - (Number(a.total_outstanding) || 0));
  }, [tab, currencyMode, currencyFilter, arByCurrency, apByCurrency, arLegacy, apLegacy, partyNames]);

  const totals = useMemo(() => {
    return rows.reduce(
      (acc, r) => ({
        current: acc.current + Number(r.current_amount || 0),
        d30: acc.d30 + Number(r.days_1_30 || 0),
        d60: acc.d60 + Number(r.days_31_60 || 0),
        d90: acc.d90 + Number(r.days_61_90 || 0),
        d91: acc.d91 + Number(r.days_91_plus || 0),
        total: acc.total + Number(r.total_outstanding || 0),
      }),
      { current: 0, d30: 0, d60: 0, d90: 0, d91: 0, total: 0 }
    );
  }, [rows]);

  if (loading) return <div className="p-8 text-center text-gray-500">جاري التحميل...</div>;

  return (
    <div className="p-6 max-w-7xl mx-auto">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-3xl font-bold bg-clip-text text-transparent bg-gradient-to-l from-primary-600 to-gold-500">
          تقرير أعمار الديون للأطراف
        </h1>
        <Link
          to="/admin/financial-parties"
          className="bg-white dark:bg-gray-800 text-gray-800 dark:text-gray-200 px-4 py-2 rounded-lg flex items-center gap-2 hover:bg-gray-50 dark:hover:bg-gray-700 shadow-lg border border-gray-100 dark:border-gray-700"
        >
          <Icons.CustomersIcon className="w-5 h-5" />
          <span>الأطراف</span>
        </Link>
      </div>

      {/* Tabs: AR / AP */}
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg border border-gray-100 dark:border-gray-700 p-3 mb-4 flex flex-wrap items-center gap-2">
        <button
          onClick={() => setTab('ar')}
          className={`px-4 py-2 rounded-lg text-sm transition-colors ${tab === 'ar' ? 'bg-primary-600 text-white shadow' : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200'}`}
        >
          ذمم مدينة (AR)
        </button>
        <button
          onClick={() => setTab('ap')}
          className={`px-4 py-2 rounded-lg text-sm transition-colors ${tab === 'ap' ? 'bg-primary-600 text-white shadow' : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200'}`}
        >
          ذمم دائنة (AP)
        </button>

        <div className="border-r border-gray-200 dark:border-gray-600 h-6 mx-2" />

        <button
          onClick={() => { setCurrencyMode('by_currency'); setCurrencyFilter(''); }}
          className={`px-3 py-1.5 rounded-lg text-xs transition-colors ${currencyMode === 'by_currency' ? 'bg-gold-500 text-white shadow' : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-200'}`}
        >
          حسب العملة
        </button>
        <button
          onClick={() => setCurrencyMode('all')}
          className={`px-3 py-1.5 rounded-lg text-xs transition-colors ${currencyMode === 'all' ? 'bg-gold-500 text-white shadow' : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-200'}`}
        >
          إجمالي (عملة الأساس)
        </button>

        {currencyMode === 'by_currency' && availableCurrencies.length > 1 && (
          <>
            <div className="border-r border-gray-200 dark:border-gray-600 h-6 mx-1" />
            {availableCurrencies.map((c) => (
              <button
                key={c}
                onClick={() => setCurrencyFilter(currencyFilter === c ? '' : c)}
                className={`px-3 py-1 rounded-full text-xs font-mono transition-colors ${currencyFilter === c
                    ? 'bg-primary-600 text-white'
                    : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-200 hover:bg-primary-100 dark:hover:bg-primary-900/30'
                  }`}
              >
                {c}
              </button>
            ))}
          </>
        )}

        <button
          onClick={() => void load()}
          className="ml-auto bg-white dark:bg-gray-800 text-gray-800 dark:text-gray-200 px-3 py-2 rounded-lg flex items-center gap-2 hover:bg-gray-50 dark:hover:bg-gray-700 border border-gray-100 dark:border-gray-700"
        >
          <Icons.ReportIcon className="w-5 h-5" />
          <span>تحديث</span>
        </button>
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3 mb-4">
        {[
          { label: 'حالي', value: totals.current, color: 'text-green-600 dark:text-green-400' },
          { label: '1-30 يوم', value: totals.d30, color: 'text-yellow-600 dark:text-yellow-400' },
          { label: '31-60 يوم', value: totals.d60, color: 'text-orange-600 dark:text-orange-400' },
          { label: '61-90 يوم', value: totals.d90, color: 'text-red-500' },
          { label: '91+ يوم', value: totals.d91, color: 'text-red-700 dark:text-red-400' },
          { label: 'الإجمالي', value: totals.total, color: 'text-primary-700 dark:text-primary-300' },
        ].map((s) => (
          <div key={s.label} className="bg-white dark:bg-gray-800 rounded-xl shadow border border-gray-100 dark:border-gray-700 p-3 text-center">
            <div className="text-xs text-gray-500 dark:text-gray-400 mb-1">{s.label}</div>
            <div className={`text-lg font-bold font-mono ${s.color}`} dir="ltr">
              {Number(s.value || 0).toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </div>
          </div>
        ))}
      </div>

      {/* Table */}
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg border border-gray-100 dark:border-gray-700 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">الطرف</th>
                {currencyMode === 'by_currency' && (
                  <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">العملة</th>
                )}
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">حالي</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">1-30</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">31-60</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">61-90</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300 border-r dark:border-gray-700">91+</th>
                <th className="p-4 text-sm font-semibold text-gray-600 dark:text-gray-300">الإجمالي</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
              {rows.length === 0 ? (
                <tr>
                  <td colSpan={currencyMode === 'by_currency' ? 8 : 7} className="p-8 text-center text-gray-500 dark:text-gray-400">
                    لا توجد بيانات.
                  </td>
                </tr>
              ) : (
                rows.map((r, i) => (
                  <tr key={`${r.party_id}-${r.currency_code}-${i}`} className="hover:bg-gray-50 dark:hover:bg-gray-700/30 transition-colors">
                    <td className="p-4 font-medium dark:text-white border-r dark:border-gray-700">
                      <div className="flex items-center justify-between gap-2">
                        <span>{r.party_name || partyNames[r.party_id] || '—'}</span>
                        <div className="flex items-center gap-3">
                          <Link
                            to={`/admin/financial-parties/${r.party_id}?print=1`}
                            className="text-primary-700 dark:text-primary-300 hover:underline text-xs"
                            title="طباعة كشف الحساب"
                          >
                            طباعة
                          </Link>
                          <Link
                            to={`/admin/financial-parties/${r.party_id}`}
                            className="text-primary-700 dark:text-primary-300 hover:underline text-xs"
                            title="عرض كشف الحساب"
                          >
                            كشف الحساب
                          </Link>
                          <Link
                            to={`/admin/settlements?partyId=${encodeURIComponent(r.party_id)}`}
                            className="text-primary-700 dark:text-primary-300 hover:underline text-xs"
                            title="فتح التسويات للطرف"
                          >
                            تسوية
                          </Link>
                          <Link
                            to={`/admin/advances?partyId=${encodeURIComponent(r.party_id)}`}
                            className="text-primary-700 dark:text-primary-300 hover:underline text-xs"
                            title="فتح الدفعات المسبقة للطرف"
                          >
                            دفعات
                          </Link>
                        </div>
                      </div>
                    </td>
                    {currencyMode === 'by_currency' && (
                      <td className="p-4 border-r dark:border-gray-700">
                        <span className="px-2 py-1 rounded-full text-xs font-mono bg-primary-50 dark:bg-primary-900/20 text-primary-700 dark:text-primary-300">
                          {r.currency_code || '—'}
                        </span>
                      </td>
                    )}
                    <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{Number(r.current_amount || 0).toFixed(2)}</td>
                    <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{Number(r.days_1_30 || 0).toFixed(2)}</td>
                    <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{Number(r.days_31_60 || 0).toFixed(2)}</td>
                    <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{Number(r.days_61_90 || 0).toFixed(2)}</td>
                    <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{Number(r.days_91_plus || 0).toFixed(2)}</td>
                    <td className="p-4 font-mono font-bold" dir="ltr">{Number(r.total_outstanding || 0).toFixed(2)}</td>
                  </tr>
                ))
              )}
            </tbody>
            {rows.length > 0 && (
              <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
                <tr>
                  <td className="p-4 border-r dark:border-gray-700" colSpan={currencyMode === 'by_currency' ? 2 : 1}>
                    المجموع
                  </td>
                  <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{totals.current.toFixed(2)}</td>
                  <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{totals.d30.toFixed(2)}</td>
                  <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{totals.d60.toFixed(2)}</td>
                  <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{totals.d90.toFixed(2)}</td>
                  <td className="p-4 border-r dark:border-gray-700 font-mono" dir="ltr">{totals.d91.toFixed(2)}</td>
                  <td className="p-4 font-mono" dir="ltr">{totals.total.toFixed(2)}</td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>
      </div>
    </div>
  );
};

export default PartyAgingReportsScreen;
