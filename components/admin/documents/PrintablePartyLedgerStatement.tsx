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
    <div className="statement-container" dir="rtl">
      <style>{`
        @media print {
          @page { size: A4; margin: 0; }
          body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        }
        .statement-container {
          font-family: 'Tajawal', 'Cairo', 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
          max-width: 210mm;
          margin: 0 auto;
          background: white;
          color: #1E3A8A;
          line-height: 1.5;
          padding: 40px;
          border-top: 5px solid #1E3A8A;
        }
        .header-section {
          display: flex;
          justify-content: space-between;
          align-items: flex-start;
          margin-bottom: 24px;
          border-bottom: 2pt solid #1E3A8A;
          padding-bottom: 16px;
        }
        .company-info { text-align: right; }
        .company-info h1 { font-size: 22px; font-weight: 800; margin: 0 0 5px 0; color: #0F172A; }
        .company-info p { margin: 2px 0; font-size: 13px; color: #1D4ED8; }
        .doc-title {
          text-align: left;
          background: #f8fafc;
          padding: 12px 20px;
          border-radius: 8px;
          border: 1.5pt solid #1E3A8A;
        }
        .doc-title h2 {
          font-size: 22px;
          font-weight: 900;
          color: #0F172A;
          margin: 0;
        }
        .doc-title .ref {
          font-size: 13px;
          color: #64748b;
          margin-top: 6px;
          font-family: 'Courier New', monospace;
        }
        .party-info {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 16px;
          margin: 18px 0;
          background: #f8fafc;
          padding: 16px;
          border-radius: 8px;
          border: 1.5pt solid #1E3A8A;
        }
        .info-item { display: flex; flex-direction: column; }
        .info-label { font-size: 11px; color: #64748b; font-weight: bold; margin-bottom: 4px; }
        .info-value { font-size: 14px; font-weight: 600; color: #0F172A; }
        .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; word-break: break-word; overflow-wrap: anywhere; }
        .summary {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 12px;
          margin-bottom: 18px;
        }
        .summary-card {
          background: #f8fafc;
          border: 1.5pt solid #1E3A8A;
          border-radius: 8px;
          padding: 12px;
        }
        .summary-card .label { font-size: 12px; color: #64748b; }
        .summary-card .value { font-size: 18px; font-weight: 800; color: #0F172A; }
        .lines-table { width: 100%; border-collapse: separate; border-spacing: 0; margin-bottom: 18px; font-size: 12px; border-radius: 8px; overflow: hidden; border: 1.5pt solid #1E3A8A; table-layout: fixed; }
        .lines-table th {
          background: #1E3A8A;
          color: white;
          font-weight: 700;
          text-align: center;
          padding: 10px;
          border-bottom: 2px solid #0F172A;
        }
        .lines-table th:first-child { text-align: right; }
        .lines-table td {
          padding: 10px;
          border-bottom: 1pt solid #DBEAFE;
          vertical-align: top;
          color: #1E40AF;
          word-break: break-word;
          overflow-wrap: anywhere;
        }
        .lines-table tr:last-child td { border-bottom: none; }
        .lines-table tr:nth-child(even) { background-color: #f8fafc; }
        .footer-meta {
          margin-top: 24px;
          border-top: 1px dashed #cbd5e1;
          padding-top: 10px;
          display: flex;
          justify-content: space-between;
          font-size: 10px;
          color: #94a3b8;
        }
      `}</style>

      <div className="header-section">
        <div className="company-info">
          {brand?.logoUrl && <img src={brand.logoUrl} alt="Logo" style={{ height: 120, marginBottom: 15 }} />}
          <h1>{AZTA_IDENTITY.tradeNameAr}</h1>
          {(brand?.name || brand?.branchName) && (
             <p style={{ fontSize: 16, fontWeight: 'bold', color: '#1E40AF', marginBottom: 5 }}>
               {brand?.name !== AZTA_IDENTITY.tradeNameAr ? brand?.name : brand?.branchName}
             </p>
          )}
          {brand?.address && <p>{brand.address}</p>}
          {brand?.contactNumber && <p dir="ltr" className="tabular">{brand.contactNumber}</p>}
        </div>
        <div className="doc-title">
          <h2>كشف حساب طرف</h2>
          <div className="ref tabular" dir="ltr">طرف: {partyName} • {shortId(partyId)}</div>
          {headerFilters && <div className="ref">{headerFilters}</div>}
        </div>
      </div>

      <div className="party-info">
        <div className="info-item">
          <span className="info-label">اسم الطرف</span>
          <span className="info-value">{partyName || '—'}</span>
        </div>
        <div className="info-item">
          <span className="info-label">المعرف</span>
          <span className="info-value tabular" dir="ltr">{shortId(partyId)}</span>
        </div>
        <div className="info-item">
          <span className="info-label">تاريخ الطباعة</span>
          <span className="info-value tabular" dir="ltr">{new Date().toLocaleString('en-GB')}</span>
        </div>
      </div>

      <div className="summary">
        {summaries.length === 0 ? (
          <div className="summary-card">
            <div className="label">ملخص</div>
            <div className="value tabular" dir="ltr">{fmt(0)}</div>
          </div>
        ) : summaries.length === 1 ? (
          <>
            <div className="summary-card">
              <div className="label">إجمالي مدين</div>
              <div className="value tabular" dir="ltr">{fmt(summaries[0].debit)}</div>
              <div style={{ fontSize: 11, color: '#64748b', marginTop: 4 }}>{summaries[0].currencyCode}</div>
            </div>
            <div className="summary-card">
              <div className="label">إجمالي دائن</div>
              <div className="value tabular" dir="ltr">{fmt(summaries[0].credit)}</div>
              <div style={{ fontSize: 11, color: '#64748b', marginTop: 4 }}>{summaries[0].currencyCode}</div>
            </div>
            <div className="summary-card">
              <div className="label">الرصيد الحالي</div>
              <div className="value tabular" dir="ltr">{fmt(summaries[0].last)}</div>
              <div style={{ fontSize: 11, color: '#64748b', marginTop: 4 }}>
                {summaries[0].currencyCode} • {summaries[0].last < 0 ? 'دائن' : summaries[0].last > 0 ? 'مدين' : 'متزن'}
              </div>
            </div>
          </>
        ) : (
          summaries.slice(0, 3).map((s) => (
            <div key={s.key} className="summary-card">
              <div className="label">{s.accountCode} • {s.currencyCode}</div>
              <div className="value tabular" dir="ltr">{fmt(s.last)}</div>
              <div style={{ fontSize: 11, color: '#64748b', marginTop: 4 }}>مدين {fmt(s.debit)} • دائن {fmt(s.credit)}</div>
            </div>
          ))
        )}
      </div>

      <table className="lines-table">
        <thead>
          <tr>
            <th style={{ width: '12%' }}>التاريخ</th>
            <th style={{ width: '10%' }}>رمز الحساب</th>
            <th style={{ width: '18%' }}>اسم الحساب</th>
            <th style={{ width: '12%' }}>مدين</th>
            <th style={{ width: '12%' }}>دائن</th>
            <th style={{ width: '12%' }}>الرصيد</th>
            <th style={{ width: '12%' }}>المصدر</th>
            <th style={{ width: '12%' }}>المتبقي/الحالة</th>
          </tr>
        </thead>
        <tbody>
          {filteredRows.length === 0 ? (
            <tr><td colSpan={8} className="text-center" style={{ padding: 28, color: '#94a3b8' }}>لا توجد حركات</td></tr>
          ) : filteredRows.map((r) => (
            <tr key={r.journal_line_id}>
              <td className="tabular" dir="ltr">{new Date(r.occurred_at).toLocaleString('en-GB')}</td>
              <td className="tabular" dir="ltr" style={{ fontWeight: 700, color: '#1D4ED8' }}>{r.account_code}</td>
              <td style={{ fontWeight: 600 }}>{r.account_name}</td>
              <td className="tabular text-center" dir="ltr" style={{ color: r.direction === 'debit' ? '#0F172A' : '#cbd5e1' }}>
                {r.direction === 'debit' ? fmt(amountInRowCurrency(r)) : '—'}
                <div style={{ fontSize: 10, color: '#64748b' }}>{String(r.currency_code || '').toUpperCase()}</div>
              </td>
              <td className="tabular text-center" dir="ltr" style={{ color: r.direction === 'credit' ? '#0F172A' : '#cbd5e1' }}>
                {r.direction === 'credit' ? fmt(amountInRowCurrency(r)) : '—'}
                <div style={{ fontSize: 10, color: '#64748b' }}>{String(r.currency_code || '').toUpperCase()}</div>
              </td>
              <td className="tabular text-center" dir="ltr">{fmt(Number((r.running_foreign_balance ?? r.running_balance) ?? 0))}</td>
              <td>
                <div className="tabular" style={{ fontSize: 11 }}>{formatSourceRefAr(r.source_table, r.source_event, r.source_id)}</div>
              </td>
              <td>
                <div className="tabular" dir="ltr" style={{ fontSize: 12 }}>
                  {(() => {
                    const curr = String(r.currency_code || '').toUpperCase();
                    const isBase = baseCode && curr === baseCode;
                    const primary = isBase ? r.open_base_amount : r.open_foreign_amount;
                    return primary == null ? '—' : fmt(Number(primary || 0));
                  })()}
                </div>
                <div style={{ fontSize: 11, color: '#64748b' }}>
                  {localizeOpenStatusAr(r.open_status)}
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <DocumentAuditFooter
        audit={{ printedAt: new Date().toISOString(), generatedBy: brand?.name || 'AZTA ERP', ...(audit || {}) }}
        extraRight={<div>{brand?.name || 'AZTA ERP'}</div>}
      />
    </div>
  );
}
