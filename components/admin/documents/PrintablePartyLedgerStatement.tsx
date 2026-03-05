import { formatDateOnly } from '../../../utils/printUtils';
import { formatSourceRefAr, localizeOpenStatusAr, shortId } from '../../../utils/displayLabels';
import { AZTA_IDENTITY } from '../../../config/identity';
import DocumentAuditFooter from './DocumentAuditFooter';
import { DocumentAuditInfo } from '../../../utils/documentStandards';

type Brand = {
  name?: string;
  address?: string;
  contactNumber?: string;
  logoUrl?: string;
  branchName?: string;
  branchCode?: string;
};

type StatementRow = {
  occurred_at: string;
  journal_entry_id: string;
  journal_line_id: string;
  account_code: string;
  account_name: string;
  direction: 'debit' | 'credit';
  foreign_amount: number | null;
  base_amount: number;
  currency_code: string;
  fx_rate: number | null;
  memo: string | null;
  source_table: string | null;
  source_id: string | null;
  source_event: string | null;
  running_balance: number;
  open_base_amount: number | null;
  open_foreign_amount: number | null;
  open_status: string | null;
  running_foreign_balance?: number | null;
  allocations?: any;
};

const fmt = (n: number) => {
  const v = Number(n || 0);
  try {
    return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  } catch {
    return v.toFixed(2);
  }
};

export default function PrintablePartyLedgerStatement(props: {
  brand?: Brand;
  partyId: string;
  partyName: string;
  accountCode?: string | null;
  currency?: string | null;
  start?: string | null;
  end?: string | null;
  rows: StatementRow[];
  printCurrencyCode?: string | null;
  printFxRate?: number | null;
  baseCurrencyCode?: string | null;
  audit?: DocumentAuditInfo | null;
}) {
  const { brand, partyId, partyName, accountCode, currency, start, end, rows, printCurrencyCode, baseCurrencyCode, audit } = props;
  const selectedCode = String(printCurrencyCode || '').trim().toUpperCase();
  const baseCode = String(baseCurrencyCode || '').trim().toUpperCase();
  const filteredRows = selectedCode
    ? rows.filter((r) => String(r.currency_code || '').trim().toUpperCase() === selectedCode)
    : rows;

  const amountInRowCurrency = (r: StatementRow) => {
    const fa = r.foreign_amount;
    if (fa == null) return Number(r.base_amount || 0) || 0;
    return Number(fa || 0) || 0;
  };

  const summaries = (() => {
    const map = new Map<string, { key: string; accountCode: string; currencyCode: string; debit: number; credit: number; last: number }>();
    for (const r of filteredRows) {
      const account = String(r.account_code || '').trim();
      const curr = String(r.currency_code || '').trim().toUpperCase() || '—';
      const key = `${account}|${curr}`;
      if (!map.has(key)) map.set(key, { key, accountCode: account, currencyCode: curr, debit: 0, credit: 0, last: 0 });
      const s = map.get(key)!;
      const amt = amountInRowCurrency(r);
      if (r.direction === 'debit') s.debit += amt;
      if (r.direction === 'credit') s.credit += amt;
      s.last = Number((r.running_foreign_balance ?? r.running_balance) ?? 0) || 0;
    }
    return Array.from(map.values());
  })();
  const periodText = [start ? formatDateOnly(start) : null, end ? formatDateOnly(end) : null]
    .filter(Boolean)
    .join(' — ');
  const headerFilters = [
    accountCode ? `الحساب: ${accountCode}` : '',
    currency ? `العملة: ${String(currency).toUpperCase()}` : '',
    periodText ? `الفترة: ${periodText}` : '',
    selectedCode ? `العملة: ${selectedCode}` : '',
  ]
    .filter(Boolean)
    .join(' • ');

  return (
    <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir="rtl">
      <style>{`
        @media print {
            @page { size: A5 portrait; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }

            .document-container { 
                width: 100% !important; 
                padding: 2mm 5mm !important;
                display: flex !important;
                flex-direction: column !important;
                font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                color: #0F172A !important;
                line-height: 1.35 !important;
                position: relative !important;
                min-height: 296mm !important;
                background-color: #FAFAFA !important;
            }

            /* ═══ WATERMARK ═══ */
            .luxury-watermark {
                position: absolute !important;
                top: 50% !important;
                left: 50% !important;
                transform: translate(-50%, -50%) rotate(-30deg) !important;
                font-size: 14rem !important;
                font-weight: 900 !important;
                color: #D4AF37 !important;
                opacity: 0.03 !important;
                white-space: nowrap !important;
                pointer-events: none !important;
                z-index: 1 !important;
                letter-spacing: -2px !important;
            }

            /* ═══ THE CERTIFICATE FRAME (ULTRA LUXURY) ═══ */
            .document-container::before {
                content: '';
                position: absolute !important;
                top: 5mm; bottom: 5mm; left: 5mm; right: 5mm;
                border: 2pt solid #1E3A8A !important;
                pointer-events: none !important;
                z-index: 50 !important;
            }
            .document-container::after {
                content: '';
                position: absolute !important;
                top: 6mm; bottom: 6mm; left: 6mm; right: 6mm;
                border: 0.5pt solid #D4AF37 !important;
                pointer-events: none !important;
                z-index: 50 !important;
            }

            /* ═══ Typography ═══ */
            .text-gold { color: #D4AF37 !important; }
            .text-charcoal { color: #0F172A !important; }
            .bg-gold-50 { background-color: #fcf9f2 !important; }
            .font-thin-label { font-weight: 300 !important; font-size: 10px !important; color: #6B7280 !important; text-transform: uppercase !important; letter-spacing: 0.5px !important; }
            .font-bold-value { font-weight: 800 !important; font-size: 13px !important; color: #0F172A !important; }
            .tabular { font-variant-numeric: tabular-nums; font-family: 'Arial', sans-serif; letter-spacing: 0.5px; }

            /* ═══ HEADER ═══ */
            .luxury-header {
                display: flex !important;
                justify-content: space-between !important;
                align-items: center !important;
                border-bottom: 1.5pt solid #1E3A8A !important;
                padding-bottom: 6px !important;
                margin-bottom: 12px !important;
            }
            .brand-name { font-size: 24px !important; font-weight: 900 !important; letter-spacing: -0.5px !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 2px !important; }
            .doc-title { font-size: 28px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #D4AF37 !important; line-height: 0.9 !important; }
            .title-sub { font-size: 9px !important; font-weight: 800 !important; letter-spacing: 2px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #D4AF37 !important; padding-top: 2px !important; margin-top: 2px !important; text-align: center !important; }
            
            /* ═══ INFO GRID ═══ */
            .info-grid {
                display: flex !important;
                justify-content: space-between !important;
                margin-bottom: 10px !important;
                background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important;
                padding: 6px 12px !important;
            }
            .info-group {
                display: flex !important;
                flex-direction: column !important;
                gap: 4px !important;
            }
            .info-item {
                display: flex !important;
                flex-direction: column !important;
            }

            /* ═══ TABLE ═══ */
            .luxury-table {
                width: 100% !important;
                border-collapse: collapse !important;
                margin-bottom: 10px !important;
                table-layout: fixed !important;
            }
            .luxury-table th {
                background-color: #0F172A !important;
                color: #FFFFFF !important;
                padding: 6px 8px !important;
                font-weight: 600 !important;
                font-size: 11px !important;
                text-transform: uppercase !important;
                letter-spacing: 0.5px !important;
                border: none !important;
            }
            .luxury-table td {
                padding: 4px 6px !important;
                font-size: 11px !important;
                font-weight: 600 !important;
                border-bottom: 0.5pt solid #E5E7EB !important;
                color: #0F172A !important;
                word-break: break-word !important;
                overflow-wrap: anywhere !important;
            }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
            .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }

             /* ═══ SUMMARY CARDS ═══ */
            .summary {
                display: flex !important;
                gap: 8px !important;
                margin-bottom: 12px !important;
            }
            .summary-card {
                flex: 1 !important;
                background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important;
                border-top: 2pt solid #1E3A8A !important;
                padding: 8px !important;
                text-align: center !important;
            }

            /* ═══ FOOTER ═══ */
            .luxury-footer {
                margin-top: auto !important;
                text-align: center !important;
                font-size: 9px !important;
                color: #4B5563 !important;
                padding-top: 6px !important;
                page-break-inside: avoid !important;
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                gap: 2px !important;
            }
            .footer-line {
                width: 60px !important;
                height: 1pt !important;
                background-color: #D4AF37 !important;
                margin: 4px 0 !important;
            }
        }
      `}</style>

      <div className="document-container w-full mx-auto p-12 bg-[#FAFAFA] flex flex-col text-blue-950 print:p-0" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }}>

        <div className="luxury-watermark">{AZTA_IDENTITY.tradeNameAr}</div>

        {/* ▬▬▬ HEADER ▬▬▬ */}
        <div className="luxury-header relative z-10 flex flex-col md:flex-row justify-between items-center md:items-end gap-6 pb-6 mb-8 border-b-2 border-slate-900 print:pb-0 print:mb-0 print:border-none print:flex-row">
          <div className="flex items-center gap-6 print:gap-4">
            {brand?.logoUrl && (
              <div className="bg-white p-2 print:p-1 print:border print:border-slate-200 z-10">
                <img src={brand.logoUrl} alt="Logo" className="h-24 print:h-16 w-auto object-contain print:grayscale" />
              </div>
            )}
            <div className="flex flex-col justify-center">
              <h1 className="brand-name">
                {AZTA_IDENTITY.tradeNameAr}
                {(brand?.name || brand?.branchName) && brand?.name !== AZTA_IDENTITY.tradeNameAr && (
                  <span className="text-sm font-normal text-slate-500 mr-2 print:text-[8px] font-sans">({brand?.name || brand?.branchName})</span>
                )}
              </h1>
              <div className="mt-2 print:mt-1 flex gap-3 text-sm print:text-[6px] text-slate-600 font-bold">
                {brand?.address && <span dir="ltr">Add: <span className="font-mono text-blue-950">{brand.address}</span></span>}
                {brand?.contactNumber && <span dir="ltr">TEL: <span className="font-mono text-blue-950">{brand.contactNumber}</span></span>}
              </div>
            </div>
          </div>

          <div className="text-center flex flex-col items-center flex-shrink-0 z-10 md:text-left rtl:text-left">
            <h2 className="doc-title">كشف حساب طرف</h2>
            <div className="title-sub">LEDGER STATEMENT</div>
          </div>
        </div>

        {/* ▬▬▬ INFO SECTION ▬▬▬ */}
        <div className="info-grid relative z-10 mb-6 print:mb-3">
          <div className="info-group">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">اسم الطرف | Party Name</span>
              <span className="font-bold-value text-gold">{partyName || '—'}</span>
            </div>
            {headerFilters && (
              <div className="info-item">
                <span className="font-thin-label">النطاق والعملة | Scope & Currency</span>
                <span className="font-bold-value text-charcoal">{headerFilters}</span>
              </div>
            )}
          </div>

          <div className="info-group border-r border-slate-300 pr-4 print:border-[#E5E7EB]">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">المعرف | ID</span>
              <span className="font-bold-value font-mono text-charcoal" dir="ltr">{shortId(partyId)}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">تاريخ الطباعة | Print Date</span>
              <span className="font-bold-value font-mono tabular" dir="ltr">{new Date().toLocaleString('en-GB')}</span>
            </div>
          </div>
        </div>

        {/* ▬▬▬ SUMMARY CARDS ▬▬▬ */}
        <div className="summary relative z-10 mb-6 print:mb-4">
          {summaries.length === 0 ? (
            <div className="summary-card">
              <div className="font-thin-label mb-1">ملخص | Summary</div>
              <div className="text-xl print:text-base font-bold text-charcoal tabular font-mono" dir="ltr">{fmt(0)}</div>
            </div>
          ) : summaries.length === 1 ? (
            <>
              <div className="summary-card">
                <div className="font-thin-label mb-1">إجمالي مدين | Total Debit</div>
                <div className="text-xl print:text-base font-bold text-charcoal tabular font-mono" dir="ltr">{fmt(summaries[0].debit)}</div>
                <div className="text-[10px] text-slate-500 mt-1">{summaries[0].currencyCode}</div>
              </div>
              <div className="summary-card">
                <div className="font-thin-label mb-1">إجمالي دائن | Total Credit</div>
                <div className="text-xl print:text-base font-bold text-charcoal tabular font-mono" dir="ltr">{fmt(summaries[0].credit)}</div>
                <div className="text-[10px] text-slate-500 mt-1">{summaries[0].currencyCode}</div>
              </div>
              <div className="summary-card bg-[#F8FAFC]">
                <div className="font-thin-label mb-1 text-gold">الرصيد الحالي | Closing Balance</div>
                <div className="text-2xl print:text-lg font-bold text-blue-950 tabular font-mono" dir="ltr">{fmt(summaries[0].last)}</div>
                <div className="text-[10px] font-bold text-blue-800 mt-1">
                  {summaries[0].currencyCode} • {summaries[0].last < 0 ? 'دائن' : summaries[0].last > 0 ? 'مدين' : 'متزن'}
                </div>
              </div>
            </>
          ) : (
            summaries.slice(0, 3).map((s) => (
              <div key={s.key} className="summary-card">
                <div className="font-thin-label mb-1">{s.accountCode} • {s.currencyCode}</div>
                <div className="text-xl print:text-base font-bold text-charcoal tabular font-mono" dir="ltr">{fmt(s.last)}</div>
                <div className="text-[10px] text-slate-500 mt-1">مدين {fmt(s.debit)} • دائن {fmt(s.credit)}</div>
              </div>
            ))
          )}
        </div>

        {/* ▬▬▬ TABLE ▬▬▬ */}
        <div className="relative z-10 w-full overflow-hidden mb-8 print:mb-4">
          <table className="luxury-table print:w-full text-right">
            <thead>
              <tr>
                <th style={{ width: '13%' }}>التاريخ</th>
                <th style={{ width: '12%' }}>رمز الحساب</th>
                <th style={{ width: '17%' }}>اسم الحساب</th>
                <th style={{ width: '12%' }} className="text-center">مدين</th>
                <th style={{ width: '12%' }} className="text-center">دائن</th>
                <th style={{ width: '12%' }} className="text-center">الرصيد</th>
                <th style={{ width: '12%' }} className="text-center">المصدر</th>
                <th style={{ width: '10%' }} className="text-center">المتبقي/الحالة</th>
              </tr>
            </thead>
            <tbody>
              {filteredRows.length === 0 ? (
                <tr>
                  <td colSpan={8} className="py-4 text-center text-slate-400">لا توجد حركات</td>
                </tr>
              ) : (
                filteredRows.map((r) => (
                  <tr key={r.journal_line_id} style={{ pageBreakInside: 'avoid' }}>
                    <td className="tabular font-thin-label text-slate-600" dir="ltr">{new Date(r.occurred_at).toLocaleString('en-GB')}</td>
                    <td className="tabular font-bold-value text-blue-900 font-mono" dir="ltr">{r.account_code}</td>
                    <td>
                      <div className="font-bold-value text-charcoal">{r.account_name}</div>
                    </td>
                    <td className="text-center tabular font-mono" dir="ltr">
                      <div className={r.direction === 'debit' ? 'font-bold text-blue-950' : 'text-slate-300'}>
                        {r.direction === 'debit' ? fmt(amountInRowCurrency(r)) : '—'}
                      </div>
                      <div className="font-thin-label text-[8px] text-slate-400">{String(r.currency_code || '').toUpperCase()}</div>
                    </td>
                    <td className="text-center tabular font-mono" dir="ltr">
                      <div className={r.direction === 'credit' ? 'font-bold text-blue-950' : 'text-slate-300'}>
                        {r.direction === 'credit' ? fmt(amountInRowCurrency(r)) : '—'}
                      </div>
                      <div className="font-thin-label text-[8px] text-slate-400">{String(r.currency_code || '').toUpperCase()}</div>
                    </td>
                    <td className="text-center tabular font-bold-value text-gold font-mono" dir="ltr">
                      {fmt(Number((r.running_foreign_balance ?? r.running_balance) ?? 0))}
                    </td>
                    <td className="text-center">
                      <div className="tabular font-thin-label text-[9px] text-slate-500">{formatSourceRefAr(r.source_table, r.source_event, r.source_id)}</div>
                    </td>
                    <td className="text-center">
                      <div className="tabular font-bold-value text-charcoal font-mono text-[10px]" dir="ltr">
                        {(() => {
                          const curr = String(r.currency_code || '').toUpperCase();
                          const isBase = baseCode && curr === baseCode;
                          const primary = isBase ? r.open_base_amount : r.open_foreign_amount;
                          return primary == null ? '—' : fmt(Number(primary || 0));
                        })()}
                      </div>
                      <div className="font-thin-label text-[9px] text-slate-400 mt-0.5">
                        {localizeOpenStatusAr(r.open_status)}
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* ▬▬▬ FOOTER ▬▬▬ */}
        <div className="luxury-footer relative z-10 w-full font-mono mt-auto pt-6">
          <div className="footer-line"></div>
          <div className="font-bold-value text-gold mb-1 print:mb-0.5 mt-1 font-sans tracking-wide">نموذج نظام مرخص — LICENSED SYSTEM FORM</div>

          <DocumentAuditFooter
            audit={{ printedAt: new Date().toISOString(), generatedBy: brand?.name || AZTA_IDENTITY.tradeNameAr, ...(audit || {}) }}
            extraRight={<div className="font-sans text-slate-400">{brand?.name || AZTA_IDENTITY.tradeNameAr}</div>}
          />
        </div>

      </div>
    </div>
  );
}
