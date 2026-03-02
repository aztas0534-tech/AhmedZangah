


import { AZTA_IDENTITY } from '../../../config/identity';

type Brand = {
  name?: string;
  address?: string;
  contactNumber?: string;
  logoUrl?: string;
  branchName?: string;
  branchCode?: string;
};

export type VoucherLine = {
  accountCode: string;
  accountName: string;
  debit: number;
  credit: number;
  memo?: string | null;
};

export type VoucherData = {
  title: string;
  voucherNumber: string;
  status?: string;
  referenceId?: string;
  date: string;
  memo?: string | null;
  currency?: string | null;
  amount?: number | null;
  amountWords?: string | null;
  lines: VoucherLine[];
  partyName?: string | null;
  paymentMethod?: string | null;
  paymentReferenceNumber?: string | null;
  senderName?: string | null;
  senderPhone?: string | null;
  receivedBy?: string | null;
  toAccount?: string | null;
  fromAccount?: string | null;
  shiftId?: string | null;
  shiftNumber?: number | null;
};

const fmt = (n: number) => {
  const v = Number(n || 0);
  try {
    return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  } catch {
    return v.toFixed(2);
  }
};

export default function PrintableVoucherBase(props: { data: VoucherData; brand?: Brand }) {
  const { data, brand } = props;
  const totalDebit = data.lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const totalCredit = data.lines.reduce((s, l) => s + Number(l.credit || 0), 0);

  // Format date safely to avoid RTL scrambling
  const formattedDate = new Date(data.date).toLocaleDateString('en-GB');
  const formattedHijriDate = (() => {
    try {
      return new Intl.DateTimeFormat('ar-SA-u-nu-latn-ca-islamic', { day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(data.date));
    } catch {
      return '';
    }
  })();
  const currency = data.currency?.toUpperCase() || '—';
  const isPosted = (() => {
    const s = String(data.status || '').trim().toLowerCase();
    if (!s) return false;
    return s === 'posted' || s.includes('posted') || s.includes('مُرحّل') || s.includes('مرحل');
  })();
  const costCenterLabel = (() => {
    const name = String(brand?.branchName || '').trim();
    const code = String(brand?.branchCode || '').trim();
    if (!name && !code) return '';
    return [name, code ? `(${code})` : ''].filter(Boolean).join(' ');
  })();
  const shiftNo = (() => {
    const n = data.shiftNumber;
    if (typeof n === 'number' && Number.isFinite(n) && n > 0) return String(Math.trunc(n));
    const id = String(data.shiftId || '').trim();
    if (!id) return '';
    const compact = id.replace(/-/g, '').toUpperCase();
    return compact.slice(-6);
  })();
  const referenceLabel = (() => {
    const t = String(data.title || '');
    if (t.includes('سند قبض') || t.includes('سند صرف')) return 'رقم المرجع';
    return 'رقم العملية';
  })();
  const actorLabel = (() => {
    const t = String(data.title || '');
    if (t.includes('سند قبض')) return 'اسم الصندوق';
    if (t.includes('سند صرف')) return 'الصارف';
    return 'المستلم';
  })();

  return (
    <div className="voucher-container" dir="rtl">
      <style>{`
            @media print {
                @page { size: A4; margin: 0; }
                body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
            }
            .voucher-container {
                font-family: 'Tajawal', 'Cairo', 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                max-width: 210mm;
                margin: 0 auto;
                background: white;
                color: #1E3A8A;
                line-height: 1.5;
                padding: 40px;
                border-top: 5px solid #1E3A8A; /* Luxury top border */
            }
            .header-section {
                display: flex;
                justify-content: space-between;
                align-items: flex-start;
                margin-bottom: 40px;
                border-bottom: 2pt solid #1E3A8A;
                padding-bottom: 20px;
            }
            .company-info { text-align: right; }
            .company-info h1 { font-size: 24px; font-weight: 800; margin: 0 0 5px 0; color: #0F172A; }
            .company-info p { margin: 2px 0; font-size: 13px; color: #1D4ED8; }
            
            .doc-title {
                text-align: left;
                background: #f8fafc;
                padding: 15px 25px;
                border-radius: 8px;
                border: 1.5pt solid #1E3A8A;
            }
            .doc-title h2 {
                font-size: 24px;
                font-weight: 900;
                color: #0F172A;
                margin: 0;
                text-transform: uppercase;
                letter-spacing: 0.5px;
            }
            .doc-title .ref-number {
                font-size: 14px;
                color: #64748b;
                margin-top: 5px;
                font-family: 'Courier New', monospace;
            }
            
            .info-grid {
                display: grid;
                grid-template-columns: repeat(4, 1fr);
                gap: 20px;
                margin-bottom: 30px;
                background: #f8fafc;
                padding: 20px;
                border-radius: 8px;
                border: 1.5pt solid #1E3A8A;
            }
            .info-item { display: flex; flex-direction: column; }
            .info-label { font-size: 11px; color: #64748b; font-weight: bold; margin-bottom: 4px; }
            .info-value { font-size: 14px; font-weight: 600; color: #0F172A; }
            .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; }
            
            .amount-box {
                grid-column: span 4;
                background: #1E3A8A;
                color: white;
                padding: 15px;
                border-radius: 6px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 30px;
            }
            .amount-box .label { font-size: 14px; font-weight: bold; }
            .amount-box .value { font-size: 20px; font-weight: 800; font-family: 'Courier New', monospace; }
            
            .lines-table { width: 100%; border-collapse: separate; border-spacing: 0; margin-bottom: 30px; font-size: 12px; border-radius: 8px; overflow: hidden; border: 1.5pt solid #1E3A8A; }
            .lines-table th {
                background: #1E3A8A;
                color: white;
                font-weight: 700;
                text-align: center;
                padding: 12px;
                border-bottom: 2px solid #0F172A;
            }
            .lines-table th:first-child { text-align: right; }
            .lines-table td {
                padding: 12px;
                border-bottom: 1pt solid #DBEAFE;
                vertical-align: top;
                color: #1E40AF;
            }
            .lines-table tr:last-child td { border-bottom: none; }
            .lines-table tr:nth-child(even) { background-color: #f8fafc; }
            .lines-table .total-row td {
                background: #f8fafc;
                font-weight: 800;
                border-top: 2px solid #cbd5e1;
                font-size: 14px;
                color: #0F172A;
            }
            
            .signatures-section {
                display: grid;
                grid-template-columns: repeat(3, 1fr);
                gap: 30px;
                margin-top: 60px;
            }
            .signature-box {
                border-top: 1px solid #cbd5e1;
                padding-top: 10px;
                text-align: center;
            }
            .signature-label { font-size: 12px; font-weight: bold; color: #64748b; margin-bottom: 40px; }
            
            .footer-meta {
                margin-top: 40px;
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
          {brand?.contactNumber && <p dir="ltr">{brand.contactNumber}</p>}
        </div>
        <div className="doc-title">
          <h2>{data.title}</h2>
          <div className="ref-number tabular" dir="ltr">#{data.voucherNumber}</div>
          <div style={{ marginTop: 10 }}>
            <span style={{ fontSize: 12, fontWeight: 'bold', background: isPosted ? '#dcfce7' : '#f1f5f9', color: isPosted ? '#166534' : '#64748b', padding: '4px 12px', borderRadius: 20 }}>
              {data.status || 'DRAFT'}
            </span>
          </div>
        </div>
      </div>

      <div className="info-grid">
        <div className="info-item">
          <span className="info-label">التاريخ</span>
          <span className="info-value tabular" dir="ltr">{formattedDate}</span>
        </div>
        {formattedHijriDate ? (
          <div className="info-item">
            <span className="info-label">التاريخ الهجري</span>
            <span className="info-value tabular" dir="ltr">{formattedHijriDate}</span>
          </div>
        ) : (
          <div className="info-item">
            <span className="info-label">التاريخ الهجري</span>
            <span className="info-value">—</span>
          </div>
        )}
        <div className="info-item">
          <span className="info-label">المعرف المرجعي</span>
          <span className="info-value tabular" dir="ltr">{data.referenceId || '—'}</span>
        </div>
        <div className="info-item" style={{ gridColumn: 'span 2' }}>
          <span className="info-label">الوصف / البيان</span>
          <span className="info-value">{data.memo || '—'}</span>
        </div>
        {costCenterLabel ? (
          <div className="info-item" style={{ gridColumn: 'span 2' }}>
            <span className="info-label">مركز التكلفة</span>
            <span className="info-value">{costCenterLabel}</span>
          </div>
        ) : null}
        {(data.title.includes('سند قبض') || data.title.includes('سند صرف')) && shiftNo ? (
          <div className="info-item">
            <span className="info-label">رقم الصندوق</span>
            <span className="info-value tabular" dir="ltr">{shiftNo}</span>
          </div>
        ) : null}
        {(data.title.includes('سند قبض') || data.title.includes('سند صرف')) && data.receivedBy ? (
          <div className="info-item">
            <span className="info-label">{actorLabel}</span>
            <span className="info-value">{data.receivedBy}</span>
          </div>
        ) : null}
        {data.partyName ? (
          <div className="info-item" style={{ gridColumn: 'span 2' }}>
            <span className="info-label">استلمنا من / الطرف</span>
            <span className="info-value">{data.partyName}</span>
          </div>
        ) : null}
        {data.paymentMethod ? (
          <div className="info-item">
            <span className="info-label">طريقة الدفع</span>
            <span className="info-value">{data.paymentMethod}</span>
          </div>
        ) : null}
        {data.paymentReferenceNumber ? (
          <div className="info-item">
            <span className="info-label">{referenceLabel}</span>
            <span className="info-value tabular" dir="ltr">{data.paymentReferenceNumber}</span>
          </div>
        ) : null}
        {(!data.title.includes('سند قبض') && !data.title.includes('سند صرف')) && data.receivedBy ? (
          <div className="info-item" style={{ gridColumn: 'span 2' }}>
            <span className="info-label">{actorLabel}</span>
            <span className="info-value">{data.receivedBy}</span>
          </div>
        ) : null}
        {data.toAccount ? (
          <div className="info-item" style={{ gridColumn: 'span 2' }}>
            <span className="info-label">إلى حساب</span>
            <span className="info-value">{data.toAccount}</span>
          </div>
        ) : null}
        {data.fromAccount ? (
          <div className="info-item" style={{ gridColumn: 'span 2' }}>
            <span className="info-label">من حساب (المقابل)</span>
            <span className="info-value">{data.fromAccount}</span>
          </div>
        ) : null}
        {(data.senderName || data.senderPhone) ? (
          <div className="info-item" style={{ gridColumn: 'span 2' }}>
            <span className="info-label">بيانات المحوّل</span>
            <span className="info-value">
              {String(data.senderName || '').trim() || '—'}
              {data.senderPhone ? <span className="tabular" dir="ltr">{` — ${data.senderPhone}`}</span> : null}
            </span>
          </div>
        ) : null}
      </div>

      {typeof data.amount === 'number' && (
        <div className="amount-box">
          <div>
            <div className="label">المبلغ الإجمالي</div>
            {data.amountWords ? <div style={{ fontSize: 11, fontWeight: 'normal', opacity: 0.85, marginTop: 4 }}>{`مبلغ وقدره: ${data.amountWords}`}</div> : null}
          </div>
          <div className="value" dir="ltr">
            {fmt(data.amount)} <span style={{ fontSize: 12 }}>{currency}</span>
          </div>
        </div>
      )}

      {data.title.includes('قيد يومية') && (
        <div className="table-container">
          <table className="lines-table">
            <thead>
              <tr>
                <th style={{ width: '15%' }}>رمز الحساب</th>
                <th style={{ width: '35%' }}>اسم الحساب</th>
                <th style={{ width: '25%' }}>البيان</th>
                <th style={{ width: '12%' }}>مدين</th>
                <th style={{ width: '12%' }}>دائن</th>
              </tr>
            </thead>
            <tbody>
              {data.lines.length === 0 ? (
                <tr><td colSpan={5} className="text-center" style={{ padding: 40, color: '#94a3b8' }}>لا توجد قيود مسجلة</td></tr>
              ) : data.lines.map((l, idx) => (
                <tr key={`${l.accountCode}-${idx}`}>
                  <td className="tabular" dir="ltr" style={{ fontWeight: 'bold', color: '#1D4ED8' }}>{l.accountCode}</td>
                  <td style={{ fontWeight: 600 }}>{l.accountName}</td>
                  <td style={{ color: '#64748b', fontSize: 11 }}>{l.memo || '—'}</td>
                  <td className="tabular text-center" dir="ltr" style={{ color: Number(l.debit) > 0 ? '#0F172A' : '#cbd5e1' }}>{Number(l.debit) > 0 ? fmt(l.debit) : '—'}</td>
                  <td className="tabular text-center" dir="ltr" style={{ color: Number(l.credit) > 0 ? '#0F172A' : '#cbd5e1' }}>{Number(l.credit) > 0 ? fmt(l.credit) : '—'}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="total-row">
                <td colSpan={3} style={{ textAlign: 'left', paddingLeft: 20 }}>الإجمالي Total</td>
                <td className="tabular text-center" dir="ltr">{fmt(totalDebit)}</td>
                <td className="tabular text-center" dir="ltr">{fmt(totalCredit)}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      <div className="signatures-section">
        <div className="signature-box">
          <div className="signature-label">
            {data.title.includes('سند قبض')
              ? 'الصندوق'
              : data.title.includes('سند صرف')
                ? 'الصارف'
                : 'إعداد (Prepared By)'}
          </div>
        </div>
        <div className="signature-box">
          <div className="signature-label">{(data.title.includes('سند قبض') || data.title.includes('سند صرف')) ? 'المدير المالي' : 'مراجعة (Checked By)'}</div>
        </div>
        <div className="signature-box">
          <div className="signature-label">{(data.title.includes('سند قبض') || data.title.includes('سند صرف')) ? 'المدير العام' : 'اعتماد (Approved By)'}</div>
        </div>
      </div>

      <div className="footer-meta">
        <div>
          تمت الطباعة بواسطة النظام في <span dir="ltr" className="tabular">{new Date().toLocaleString('en-GB')}</span>
        </div>
        <div>
          Generated by {brand?.name || 'AZTA ERP'}
        </div>
      </div>
    </div>
  );
}
