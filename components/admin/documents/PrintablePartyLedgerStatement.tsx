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

  const systemName = brand?.name || AZTA_IDENTITY.tradeNameAr;
  const systemKey = AZTA_IDENTITY.merchantKey;
  const branchName = (brand?.branchName || '').trim();
  const showBranch = Boolean(branchName) && branchName !== systemName;

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

            .stmt-container { 
                width: 100% !important; 
                padding: 3mm 3mm 2mm 3mm !important;
                display: flex !important; flex-direction: column !important;
                font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                color: #0F172A !important; line-height: 1.2 !important;
                position: relative !important; background-color: #FAFAFA !important;
            }

            .luxury-watermark {
                position: absolute !important; top: 50% !important; left: 50% !important;
                transform: translate(-50%, -50%) rotate(-30deg) !important;
                font-size: 12rem !important; font-weight: 900 !important;
                color: #D4AF37 !important; opacity: 0.03 !important;
                white-space: nowrap !important; pointer-events: none !important; z-index: 1 !important;
            }

            .stmt-container::before {
                content: ''; position: absolute !important;
                top: 1mm; bottom: 1mm; left: 1mm; right: 1mm;
                border: 1.5pt solid #1E3A8A !important;
                pointer-events: none !important; z-index: 50 !important;
            }
            .stmt-container::after {
                content: ''; position: absolute !important;
                top: 2mm; bottom: 2mm; left: 2mm; right: 2mm;
                border: 0.5pt solid #D4AF37 !important;
                pointer-events: none !important; z-index: 50 !important;
            }

            .font-thin-label { font-weight: 800 !important; font-size: 10px !important; color: #111827 !important; text-transform: uppercase !important; letter-spacing: 0.3px !important; }
            .font-bold-value { font-weight: 900 !important; font-size: 12px !important; color: #000000 !important; }

            .luxury-header {
                display: flex !important; justify-content: space-between !important;
                align-items: center !important; border-bottom: 1.5pt solid #1E3A8A !important;
                padding-bottom: 2px !important; margin-bottom: 4px !important;
            }
            .brand-name { font-size: 18px !important; font-weight: 900 !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 1px !important; }
            .stmt-title { font-size: 22px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #D4AF37 !important; line-height: 0.9 !important; }
            .title-sub { font-size: 8px !important; font-weight: 800 !important; letter-spacing: 1.5px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #D4AF37 !important; padding-top: 1px !important; margin-top: 1px !important; text-align: center !important; }

            .info-grid {
                display: flex !important; justify-content: space-between !important;
                margin-bottom: 3px !important; background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important; padding: 2px 5px !important;
            }
            .info-group { display: flex !important; flex-direction: column !important; gap: 1px !important; }
            .info-item { display: flex !important; flex-direction: column !important; }

            .summary-cards {
                display: flex !important; gap: 4px !important; margin-bottom: 3px !important;
            }
            .summary-card {
                flex: 1 !important; border: 0.5pt solid #E5E7EB !important;
                border-top: 1.5pt solid #1E3A8A !important;
                padding: 3px !important; text-align: center !important; background: white !important;
            }

            .luxury-table { width: 100% !important; border-collapse: collapse !important; margin-bottom: 3px !important; }
            .luxury-table thead { display: table-header-group !important; }
            .luxury-table th {
                background-color: #0F172A !important; color: #FFFFFF !important;
                padding: 1.5px 2px !important; font-weight: 700 !important;
                font-size: 9px !important; text-transform: uppercase !important; border: none !important;
            }
            .luxury-table td {
                padding: 1px 2px !important; font-size: 9px !important; font-weight: 700 !important;
                line-height: 1 !important; border-bottom: 0.5pt solid #E5E7EB !important; color: #0F172A !important;
            }
            .luxury-table tr { page-break-inside: avoid !important; }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
            .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }

            .luxury-footer {
                margin-top: auto !important; text-align: center !important;
                font-size: 7px !important; color: #4B5563 !important; padding-top: 2px !important;
                page-break-inside: avoid !important;
            }
            .footer-line { width: 40px !important; height: 0.5pt !important; background-color: #D4AF37 !important; margin: 1px auto !important; }
        }

        @media screen {
            .stmt-container { max-width: 700px; margin: 0 auto; padding: 24px; background: #FAFAFA; font-family: 'Tajawal', 'Cairo', sans-serif; }
            .luxury-header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #1E3A8A; padding-bottom: 12px; margin-bottom: 16px; }
            .brand-name { font-size: 18px; font-weight: 900; color: #0F172A; }
            .stmt-title { font-size: 28px; font-weight: 800; color: #D4AF37; }
            .title-sub { font-size: 10px; font-weight: 800; color: #0F172A; text-transform: uppercase; border-top: 1px solid #D4AF37; padding-top: 2px; margin-top: 2px; text-align: center; }
            .info-grid { display: flex; justify-content: space-between; margin-bottom: 16px; background: #F3F4F6; border: 1px solid #E5E7EB; padding: 8px 12px; border-radius: 4px; }
            .info-group { display: flex; flex-direction: column; gap: 4px; }
            .info-item { display: flex; flex-direction: column; }
            .font-thin-label { font-weight: 700; font-size: 11px; color: #6B7280; text-transform: uppercase; letter-spacing: 0.5px; }
            .font-bold-value { font-weight: 800; font-size: 13px; color: #0F172A; }
            .summary-cards { display: flex; gap: 8px; margin-bottom: 16px; }
            .summary-card { flex: 1; border: 1px solid #E5E7EB; border-top: 3px solid #1E3A8A; padding: 8px; text-align: center; background: white; border-radius: 4px; }
            .luxury-table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
            .luxury-table th { background-color: #0F172A; color: #FFFFFF; padding: 6px 8px; font-weight: 700; font-size: 11px; text-transform: uppercase; }
            .luxury-table td { padding: 4px 6px; font-size: 11px; font-weight: 700; border-bottom: 1px solid #E5E7EB; color: #0F172A; }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB; }
            .luxury-table tr:last-child td { border-bottom: 2px solid #1E3A8A; }
            .luxury-watermark { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%) rotate(-30deg); font-size: 8rem; font-weight: 900; color: #D4AF37; opacity: 0.04; pointer-events: none; z-index: 1; }
            .luxury-footer { margin-top: 16px; text-align: center; font-size: 10px; color: #6B7280; }
            .footer-line { width: 40px; height: 1px; background-color: #D4AF37; margin: 4px auto; }
        }
      `}</style>

      <div className="stmt-container" style={{ fontFamily: 'Tajawal, Cairo, sans-serif', position: 'relative' }}>

        <div className="luxury-watermark">{systemName}</div>

        {/* ▬▬▬ HEADER ▬▬▬ */}
        <div className="luxury-header" style={{ position: 'relative', zIndex: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
            {brand?.logoUrl && (
              <div style={{ background: 'white', padding: '4px', marginTop: '4px', zIndex: 10 }}>
                <img src={brand.logoUrl} alt="Logo" style={{ height: '70px', width: 'auto', objectFit: 'contain' }} />
              </div>
            )}
            <div style={{ display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
              <h1 className="brand-name">
                {systemName}
                {showBranch && <span style={{ fontSize: '10px', fontWeight: 'normal', color: '#64748B', marginRight: '8px' }}>({branchName})</span>}
              </h1>
              {systemKey && <div style={{ fontSize: '8px', color: '#64748B', textTransform: 'uppercase', letterSpacing: '0.3em', fontFamily: 'monospace' }} dir="ltr">{systemKey}</div>}
              <div style={{ marginTop: '2px', display: 'flex', gap: '12px', fontSize: '8px', fontWeight: 'bold', color: '#334155' }}>
                {brand?.address && <span dir="ltr">Add: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{brand.address}</span></span>}
                {brand?.contactNumber && <span dir="ltr">TEL: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{brand.contactNumber}</span></span>}
              </div>
            </div>
          </div>

          <div style={{ textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0, zIndex: 10 }}>
            <h2 className="stmt-title">كشف حساب</h2>
            <div className="title-sub">PARTY LEDGER STATEMENT</div>
          </div>
        </div>

        {/* ▬▬▬ INFO SECTION ▬▬▬ */}
        <div className="info-grid" style={{ position: 'relative', zIndex: 10 }}>
          <div className="info-group">
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">اسم الطرف | Party Name</span>
              <span className="font-bold-value">{partyName || '—'}</span>
            </div>
            {headerFilters && (
              <div className="info-item">
                <span className="font-thin-label">النطاق | Scope &amp; Filters</span>
                <span className="font-bold-value" style={{ fontSize: '10px' }}>{headerFilters}</span>
              </div>
            )}
          </div>

          <div className="info-group" style={{ borderRight: '1px solid #E5E7EB', paddingRight: '12px' }}>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">المعرف | ID</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{shortId(partyId)}</span>
            </div>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">عدد الحركات | Entries</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{filteredRows.length}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">تاريخ الطباعة | Print Date</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{new Date().toLocaleString('en-GB')}</span>
            </div>
          </div>
        </div>

        {/* ▬▬▬ SUMMARY CARDS ▬▬▬ */}
        <div className="summary-cards" style={{ position: 'relative', zIndex: 10 }}>
          {summaries.length === 0 ? (
            <div className="summary-card">
              <div className="font-thin-label" style={{ marginBottom: '2px' }}>ملخص | Summary</div>
              <div style={{ fontSize: '16px', fontWeight: 800, fontFamily: 'monospace', color: '#0F172A' }} dir="ltr">{fmt(0)}</div>
            </div>
          ) : summaries.length === 1 ? (
            <>
              <div className="summary-card">
                <div className="font-thin-label" style={{ marginBottom: '2px' }}>إجمالي مدين | Total Debit</div>
                <div style={{ fontSize: '16px', fontWeight: 800, fontFamily: 'monospace', color: '#0F172A' }} dir="ltr">{fmt(summaries[0].debit)}</div>
                <div style={{ fontSize: '8px', color: '#6B7280', marginTop: '2px' }}>{summaries[0].currencyCode}</div>
              </div>
              <div className="summary-card">
                <div className="font-thin-label" style={{ marginBottom: '2px' }}>إجمالي دائن | Total Credit</div>
                <div style={{ fontSize: '16px', fontWeight: 800, fontFamily: 'monospace', color: '#0F172A' }} dir="ltr">{fmt(summaries[0].credit)}</div>
                <div style={{ fontSize: '8px', color: '#6B7280', marginTop: '2px' }}>{summaries[0].currencyCode}</div>
              </div>
              <div className="summary-card" style={{ background: '#EFF6FF', borderTopColor: '#D4AF37' }}>
                <div className="font-thin-label" style={{ marginBottom: '2px', color: '#1E3A8A' }}>الرصيد الحالي | Closing</div>
                <div style={{ fontSize: '18px', fontWeight: 900, fontFamily: 'monospace', color: '#0F172A' }} dir="ltr">{fmt(summaries[0].last)}</div>
                <div style={{ fontSize: '8px', fontWeight: 800, color: '#1E40AF', marginTop: '2px' }}>
                  {summaries[0].currencyCode} • {summaries[0].last < 0 ? 'دائن' : summaries[0].last > 0 ? 'مدين' : 'متزن'}
                </div>
              </div>
            </>
          ) : (
            summaries.slice(0, 3).map((s) => (
              <div key={s.key} className="summary-card">
                <div className="font-thin-label" style={{ marginBottom: '2px' }}>{s.accountCode} • {s.currencyCode}</div>
                <div style={{ fontSize: '16px', fontWeight: 800, fontFamily: 'monospace', color: '#0F172A' }} dir="ltr">{fmt(s.last)}</div>
                <div style={{ fontSize: '8px', color: '#6B7280', marginTop: '2px' }}>مدين {fmt(s.debit)} • دائن {fmt(s.credit)}</div>
              </div>
            ))
          )}
        </div>

        {/* ▬▬▬ TABLE ▬▬▬ */}
        <div style={{ position: 'relative', zIndex: 10, width: '100%' }}>
          <table className="luxury-table" style={{ textAlign: 'right' }}>
            <thead>
              <tr>
                <th style={{ width: '11%', textAlign: 'right' }}>التاريخ</th>
                <th style={{ width: '7%', textAlign: 'center' }}>رمز</th>
                <th style={{ width: '16%', textAlign: 'right' }}>اسم الحساب</th>
                <th style={{ width: '14%', textAlign: 'center' }}>مدين DEBIT</th>
                <th style={{ width: '14%', textAlign: 'center' }}>دائن CREDIT</th>
                <th style={{ width: '14%', textAlign: 'center' }}>الرصيد BAL</th>
                <th style={{ width: '13%', textAlign: 'center' }}>المصدر</th>
                <th style={{ width: '11%', textAlign: 'center' }}>المتبقي</th>
              </tr>
            </thead>
            <tbody>
              {filteredRows.length === 0 ? (
                <tr>
                  <td colSpan={8} style={{ textAlign: 'center', padding: '12px', color: '#9CA3AF' }}>لا توجد حركات</td>
                </tr>
              ) : (
                filteredRows.map((r) => (
                  <tr key={r.journal_line_id} style={{ pageBreakInside: 'avoid' }}>
                    <td style={{ fontFamily: 'monospace', color: '#6B7280', lineHeight: 1 }} dir="ltr">
                      <div>{new Date(r.occurred_at).toLocaleDateString('en-GB')}</div>
                      <div style={{ fontSize: '6px', marginTop: '1px' }}>{new Date(r.occurred_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</div>
                    </td>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace', color: '#1E40AF', fontWeight: 800 }} dir="ltr">{r.account_code}</td>
                    <td>
                      <div style={{ fontWeight: 800, color: '#0F172A' }}>{r.account_name}</div>
                    </td>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace' }} dir="ltr">
                      <div style={{ fontWeight: r.direction === 'debit' ? 800 : 400, color: r.direction === 'debit' ? '#0F172A' : '#D1D5DB' }}>
                        {r.direction === 'debit' ? fmt(amountInRowCurrency(r)) : '—'}
                      </div>
                      <div style={{ fontSize: '6px', color: '#9CA3AF' }}>{String(r.currency_code || '').toUpperCase()}</div>
                    </td>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace' }} dir="ltr">
                      <div style={{ fontWeight: r.direction === 'credit' ? 800 : 400, color: r.direction === 'credit' ? '#0F172A' : '#D1D5DB' }}>
                        {r.direction === 'credit' ? fmt(amountInRowCurrency(r)) : '—'}
                      </div>
                      <div style={{ fontSize: '6px', color: '#9CA3AF' }}>{String(r.currency_code || '').toUpperCase()}</div>
                    </td>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace', fontWeight: 900, color: '#0F172A' }} dir="ltr">
                      {fmt(Number((r.running_foreign_balance ?? r.running_balance) ?? 0))}
                    </td>
                    <td style={{ textAlign: 'center' }}>
                      <div style={{ fontFamily: 'monospace', fontSize: '8px', color: '#6B7280' }}>{formatSourceRefAr(r.source_table, r.source_event, r.source_id)}</div>
                    </td>
                    <td style={{ textAlign: 'center' }}>
                      <div style={{ fontFamily: 'monospace', fontWeight: 800, color: '#0F172A', fontSize: '9px' }} dir="ltr">
                        {(() => {
                          const curr = String(r.currency_code || '').toUpperCase();
                          const isBase = baseCode && curr === baseCode;
                          const primary = isBase ? r.open_base_amount : r.open_foreign_amount;
                          return primary == null ? '—' : fmt(Number(primary || 0));
                        })()}
                      </div>
                      <div style={{ fontSize: '7px', color: '#9CA3AF', marginTop: '1px' }}>
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
        <div className="luxury-footer" style={{ position: 'relative', zIndex: 10 }}>
          <div className="footer-line" />
          <div style={{ fontSize: '7px', color: '#6B7280' }}>
            هذا المستند صادر إلكترونياً ولا يحتاج إلى ختم — This document is electronically generated
          </div>
          <div className="footer-line" />
          <DocumentAuditFooter
            audit={{ printedAt: new Date().toISOString(), generatedBy: systemName, ...(audit || {}) }}
            extraRight={<span style={{ color: '#9CA3AF', fontSize: '7px' }}>{systemName}</span>}
          />
        </div>

      </div>
    </div>
  );
}
