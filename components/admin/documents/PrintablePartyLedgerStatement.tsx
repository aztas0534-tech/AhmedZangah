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
    <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0" dir="rtl">
      <style>{`
        @media print {
            @page { size: auto; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }

            .document-container { 
                width: 100% !important; 
                padding: 5mm !important;
                display: flex !important;
                flex-direction: column !important;
                font-family: 'Tahoma', 'Arial', sans-serif !important;
                color: #000 !important;
                line-height: 1.4 !important;
                position: relative !important;
                background-color: white !important;
            }

            /* ═══ WATERMARK ═══ */
            .luxury-watermark {
                position: fixed !important;
                top: 30% !important;
                left: 50% !important;
                transform: translate(-50%, -50%) rotate(-45deg) !important;
                font-size: 40px !important;
                font-weight: bold !important;
                color: rgba(0,0,0,0.06) !important;
                white-space: nowrap !important;
                pointer-events: none !important;
                z-index: 0 !important;
                border: 3px solid rgba(0,0,0,0.06) !important;
                padding: 8px 30px !important;
            }

            /* ═══ FRAME — disabled for auto sizing ═══ */
            .document-container::before { display: none !important; }
            .document-container::after { display: none !important; }

            /* ═══ Typography ═══ */
            .text-gold { color: #000 !important; }
            .text-charcoal { color: #000 !important; }
            .bg-gold-50 { background-color: #f8f8f8 !important; }
            .font-thin-label { font-weight: normal !important; font-size: 10px !important; color: #444 !important; }
            .font-bold-value { font-weight: bold !important; font-size: 12px !important; color: #000 !important; }
            .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; letter-spacing: -0.5px; }

            /* ═══ LOGO ═══ */
            .brand-logo-box {
                overflow: hidden !important;
                display: flex !important;
                align-items: center !important;
                justify-content: center !important;
            }
            .brand-logo {
                height: 60px !important;
                width: auto !important;
                object-fit: contain !important;
                display: block !important;
            }

            /* ═══ HEADER ═══ */
            .luxury-header {
                display: flex !important;
                justify-content: space-between !important;
                align-items: center !important;
                border-bottom: 1px dashed #000 !important;
                padding-bottom: 5px !important;
                margin-bottom: 8px !important;
            }
            .brand-name { font-size: 15px !important; font-weight: bold !important; line-height: 1.2 !important; color: #000 !important; margin-bottom: 2px !important; }
            .doc-title { font-size: 18px !important; font-weight: bold !important; color: #000 !important; line-height: 1 !important; }
            .title-sub { font-size: 10px !important; font-weight: bold !important; color: #444 !important; text-transform: uppercase !important; border-top: 1px solid #ccc !important; padding-top: 2px !important; margin-top: 2px !important; text-align: center !important; }
            
            /* ═══ INFO GRID ═══ */
            .info-grid {
                display: flex !important;
                justify-content: space-between !important;
                margin-bottom: 8px !important;
                border: 1px solid #ccc !important;
                padding: 4px 8px !important;
            }
            .info-group {
                display: flex !important;
                flex-direction: column !important;
                gap: 2px !important;
            }
            .info-item {
                display: flex !important;
                flex-direction: column !important;
            }

            /* ═══ TABLE ═══ */
            .luxury-table {
                width: 100% !important;
                border-collapse: collapse !important;
                margin-bottom: 8px !important;
            }
            .luxury-table th {
                background-color: #000 !important;
                color: #fff !important;
                padding: 4px 6px !important;
                font-weight: bold !important;
                font-size: 11px !important;
                border: 1px solid #000 !important;
                text-align: right !important;
            }
            .luxury-table td {
                padding: 3px 6px !important;
                font-size: 11px !important;
                font-weight: normal !important;
                border-bottom: 1px solid #ddd !important;
                color: #000 !important;
            }
            .luxury-table tr:nth-child(even) td { background-color: #f9f9f9 !important; }
            .luxury-table tr:last-child td { border-bottom: 2px solid #000 !important; }

             /* ═══ SUMMARY CARDS ═══ */
            .summary {
                display: flex !important;
                gap: 6px !important;
                margin-bottom: 8px !important;
            }
            .summary-card {
                flex: 1 !important;
                border: 1px solid #ccc !important;
                border-top: 2px solid #000 !important;
                padding: 4px !important;
                text-align: center !important;
            }

            /* ═══ FOOTER ═══ */
            .luxury-footer {
                margin-top: auto !important;
                text-align: center !important;
                font-size: 10px !important;
                color: #444 !important;
                padding-top: 4px !important;
                border-top: 1px dashed #000 !important;
                page-break-inside: avoid !important;
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                gap: 2px !important;
            }
            .footer-line {
                width: 40px !important;
                height: 1px !important;
                background-color: #000 !important;
                margin: 2px 0 !important;
            }
        }
      `}</style>

      <div className="document-container w-full mx-auto p-12 bg-[#FAFAFA] flex flex-col text-blue-950 print:p-0" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }}>

        <div className="luxury-watermark">{AZTA_IDENTITY.tradeNameAr}</div>

        {/* ▬▬▬ HEADER ▬▬▬ */}
        <div className="luxury-header relative z-10 flex flex-col md:flex-row justify-between items-center md:items-end gap-6 pb-6 mb-8 border-b-2 border-slate-900 print:pb-0 print:mb-0 print:border-none print:flex-row">
          <div className="flex items-center gap-6 print:gap-4">
            {brand?.logoUrl && (
              <div className="brand-logo-box bg-white p-2 print:p-1 print:border print:border-slate-200 z-10">
                <img src={brand.logoUrl} alt="Logo" className="brand-logo h-24 print:h-16 w-auto object-contain print:grayscale" />
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
                <div className="text-xl print:text-sm font-bold text-charcoal tabular font-mono" dir="ltr">{fmt(summaries[0].debit)}</div>
                <div className="text-[10px] print:text-[7px] text-slate-500 mt-1">{summaries[0].currencyCode}</div>
              </div>
              <div className="summary-card">
                <div className="font-thin-label mb-1">إجمالي دائن | Total Credit</div>
                <div className="text-xl print:text-sm font-bold text-charcoal tabular font-mono" dir="ltr">{fmt(summaries[0].credit)}</div>
                <div className="text-[10px] print:text-[7px] text-slate-500 mt-1">{summaries[0].currencyCode}</div>
              </div>
              <div className="summary-card bg-[#F8FAFC]">
                <div className="font-thin-label mb-1 text-gold">الرصيد الحالي | Closing Balance</div>
                <div className="text-2xl print:text-sm font-bold text-blue-950 tabular font-mono" dir="ltr">{fmt(summaries[0].last)}</div>
                <div className="text-[10px] print:text-[7px] font-bold text-blue-800 mt-1">
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
        <div className="relative z-10 w-full overflow-visible mb-8 print:mb-4">
          <table className="luxury-table print:w-full text-right">
            <thead>
              <tr>
                <th style={{ width: '11%' }}>التاريخ</th>
                <th style={{ width: '7%' }}>رمز الحساب</th>
                <th style={{ width: '16%' }}>اسم الحساب</th>
                <th style={{ width: '15%' }} className="text-center">مدين</th>
                <th style={{ width: '15%' }} className="text-center">دائن</th>
                <th style={{ width: '14%' }} className="text-center">الرصيد</th>
                <th style={{ width: '11%' }} className="text-center">المصدر</th>
                <th style={{ width: '11%' }} className="text-center">المتبقي</th>
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
                    <td className="tabular font-thin-label text-slate-600 leading-tight" dir="ltr">
                      <div>{new Date(r.occurred_at).toLocaleDateString('en-GB')}</div>
                      <div className="text-[5.5px] mt-0.5">{new Date(r.occurred_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</div>
                    </td>
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
