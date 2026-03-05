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
  currency?: string | null;
  analyticalAccount?: string | null;
  costCenterNo?: string | null;
  referenceNo?: string | null;
  foreignDebit?: number | null;
  foreignCredit?: number | null;
  recordNo?: string | number | null;
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
  shiftName?: string | null;
  foreignAmount?: number | null;
  fxRate?: number | null;
  baseCurrency?: string | null;
  createdBy?: string | null;
  attachmentsCount?: number | null;
};

const fmt = (n: number | null | undefined) => {
  const v = Number(n || 0);
  if (v === 0) return '';
  try {
    return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  } catch {
    return v.toFixed(2);
  }
};

const cleanName = (name: string | null | undefined) => {
  if (!name) return '—';
  const str = String(name).trim();
  if (str.includes('@')) {
    return str.split('@')[0].replace(/[._-]/g, ' ');
  }
  return str;
};

export default function PrintableVoucherBase(props: { data: VoucherData; brand?: Brand }) {
  const { data, brand } = props;
  const isJournal = data.title.includes('قيد يومية') || data.title.includes('JV');
  const isReceipt = data.title.includes('سند قبض');
  const isPayment = data.title.includes('سند صرف');

  const totalDebit = data.lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const totalCredit = data.lines.reduce((s, l) => s + Number(l.credit || 0), 0);

  const displayLines = isJournal
    ? data.lines
    : data.lines.filter(l => {
      if (isReceipt) return Number(l.credit) > 0;
      else if (isPayment) return Number(l.debit) > 0;
      return true;
    });

  const linesToRender = displayLines.length > 0 ? displayLines : data.lines;

  const formattedDate = new Date(data.date).toLocaleDateString('en-GB');
  const formattedHijriDate = (() => {
    try {
      return new Intl.DateTimeFormat('ar-SA-u-nu-latn-ca-islamic', { day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(data.date));
    } catch {
      return '';
    }
  })();

  const currency = data.currency?.toUpperCase() || 'YER';
  const shiftNo = (() => {
    const n = data.shiftNumber;
    if (typeof n === 'number' && Number.isFinite(n) && n > 0) return String(Math.trunc(n));
    const id = String(data.shiftId || '').trim();
    if (!id) return '';
    const compact = id.replace(/-/g, '').toUpperCase();
    return compact.slice(-6);
  })();

  const voucherTitle = isJournal ? 'قيد يومية' : (isReceipt ? 'سند قبض' : (isPayment ? 'سند صرف' : data.title));
  const voucherSubTitle = isJournal ? 'JOURNAL VOUCHER' : isPayment ? 'PAYMENT VOUCHER' : 'RECEIPT VOUCHER';
  const payMethodLabel = data.paymentMethod === 'cash' ? 'نقداً' : data.paymentMethod === 'bank' || data.paymentMethod === 'bank_transfer' ? 'تحويل بنكي' : data.paymentMethod === 'network' ? 'شبكة' : 'نقداً';

  return (
    <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir="rtl">
      <style>{`
        @media print {
            @page { size: A5 landscape; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }
            img { max-height: 40px !important; max-width: 100px !important; height: auto !important; width: auto !important; object-fit: contain !important; }

            .vc {
                width: 100% !important;
                padding: 3mm 5mm !important;
                font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                color: #0F172A !important;
                line-height: 1.3 !important;
                position: relative !important;
                max-height: 148mm !important;
                overflow: hidden !important;
                background-color: white !important;
                font-size: 9px !important;
            }

            /* Frame borders */
            .vc::before {
                content: '';
                position: absolute !important;
                top: 1.5mm; bottom: 1.5mm; left: 1.5mm; right: 1.5mm;
                border: 1.5pt solid #1E3A8A !important;
                pointer-events: none !important;
                z-index: 50 !important;
            }
            .vc::after {
                content: '';
                position: absolute !important;
                top: 2.5mm; bottom: 2.5mm; left: 2.5mm; right: 2.5mm;
                border: 0.5pt solid #D4AF37 !important;
                pointer-events: none !important;
                z-index: 50 !important;
            }

            /* Header */
            .vc-header {
                display: flex !important;
                justify-content: space-between !important;
                align-items: flex-start !important;
                border-bottom: 1.5pt solid #1E3A8A !important;
                padding-bottom: 3px !important;
                margin-bottom: 4px !important;
            }
            .vc-brand-name { font-size: 14px !important; font-weight: 900 !important; color: #0F172A !important; margin: 0 !important; line-height: 1.1 !important; }
            .vc-brand-sub { font-size: 6px !important; color: #4B5563 !important; margin: 1px 0 !important; }
            .vc-logo { max-height: 32px !important; width: auto !important; }
            .vc-title-box {
                text-align: center !important;
                background: linear-gradient(135deg, #1E3A8A 0%, #0F172A 100%) !important;
                color: white !important;
                padding: 3px 16px !important;
                border-radius: 3px !important;
                border: 1pt solid #D4AF37 !important;
            }
            .vc-title { font-size: 16px !important; font-weight: 900 !important; color: #D4AF37 !important; margin: 0 !important; }
            .vc-title-en { font-size: 6px !important; color: #93C5FD !important; letter-spacing: 1px !important; text-transform: uppercase !important; }
            .vc-title-method { font-size: 8px !important; color: white !important; font-weight: 700 !important; margin-top: 1px !important; }

            /* Info fields row */
            .vc-info-row {
                display: flex !important;
                gap: 0 !important;
                margin-bottom: 4px !important;
                border: 1pt solid #1E3A8A !important;
                border-radius: 2px !important;
                overflow: hidden !important;
            }
            .vc-field {
                flex: 1 !important;
                display: flex !important;
                border-left: 0.5pt solid #CBD5E1 !important;
            }
            .vc-field:last-child { border-left: none !important; }
            .vc-field-label {
                background: #EFF6FF !important;
                padding: 2px 4px !important;
                font-size: 7px !important;
                font-weight: 700 !important;
                color: #1E3A8A !important;
                white-space: nowrap !important;
                display: flex !important;
                align-items: center !important;
                border-left: 0.5pt solid #CBD5E1 !important;
                min-width: 45px !important;
            }
            .vc-field-value {
                padding: 2px 4px !important;
                font-size: 9px !important;
                font-weight: 700 !important;
                color: #0F172A !important;
                display: flex !important;
                align-items: center !important;
                flex: 1 !important;
                font-family: 'Arial', sans-serif !important;
            }

            /* Party line */
            .vc-party-row {
                display: flex !important;
                border: 1pt solid #1E3A8A !important;
                border-radius: 2px !important;
                margin-bottom: 4px !important;
                overflow: hidden !important;
            }
            .vc-party-label {
                background: #EFF6FF !important;
                padding: 2px 6px !important;
                font-size: 8px !important;
                font-weight: 700 !important;
                color: #1E3A8A !important;
                white-space: nowrap !important;
                display: flex !important;
                align-items: center !important;
                border-left: 0.5pt solid #CBD5E1 !important;
            }
            .vc-party-value {
                padding: 2px 8px !important;
                font-size: 10px !important;
                font-weight: 800 !important;
                color: #0F172A !important;
                display: flex !important;
                align-items: center !important;
                flex: 1 !important;
            }

            /* Amount row */
            .vc-amount-row {
                display: flex !important;
                border: 1.5pt solid #1E3A8A !important;
                border-radius: 2px !important;
                margin-bottom: 4px !important;
                overflow: hidden !important;
                background: #FEFCE8 !important;
            }
            .vc-amount-label {
                background: #1E3A8A !important;
                padding: 3px 6px !important;
                font-size: 8px !important;
                font-weight: 700 !important;
                color: #D4AF37 !important;
                white-space: nowrap !important;
                display: flex !important;
                align-items: center !important;
            }
            .vc-amount-words {
                padding: 3px 8px !important;
                font-size: 10px !important;
                font-weight: 800 !important;
                color: #0F172A !important;
                display: flex !important;
                align-items: center !important;
                flex: 1 !important;
            }
            .vc-amount-number {
                background: #1E3A8A !important;
                padding: 3px 8px !important;
                font-size: 12px !important;
                font-weight: 900 !important;
                color: #D4AF37 !important;
                display: flex !important;
                align-items: center !important;
                gap: 3px !important;
                font-family: 'Arial', sans-serif !important;
                white-space: nowrap !important;
            }
            .vc-amount-currency {
                font-size: 8px !important;
                color: #93C5FD !important;
                font-weight: 600 !important;
            }

            /* Account label */
            .vc-account-label {
                font-size: 9px !important;
                font-weight: 800 !important;
                color: #1E3A8A !important;
                margin-bottom: 2px !important;
                padding-right: 4px !important;
            }

            /* Table */
            .vc-table {
                width: 100% !important;
                border-collapse: collapse !important;
                margin-bottom: 4px !important;
                border: 1pt solid #1E3A8A !important;
                font-size: 9px !important;
            }
            .vc-table th {
                background: #1E3A8A !important;
                color: white !important;
                padding: 2px 3px !important;
                font-weight: 700 !important;
                font-size: 7px !important;
                text-align: center !important;
                border: 0.5pt solid #1E3A8A !important;
                white-space: nowrap !important;
            }
            .vc-table td {
                padding: 2px 3px !important;
                font-size: 9px !important;
                font-weight: 600 !important;
                border: 0.5pt solid #CBD5E1 !important;
                color: #0F172A !important;
                text-align: center !important;
            }
            .vc-table tr:nth-child(even) td { background: #F8FAFC !important; }
            .vc-table tfoot td {
                background: #0F172A !important;
                color: #D4AF37 !important;
                font-weight: 800 !important;
                border: 1pt solid #1E3A8A !important;
            }

            /* Entry / Creator info */
            .vc-entry-info {
                font-size: 8px !important;
                color: #4B5563 !important;
                margin-bottom: 4px !important;
            }
            .vc-entry-info strong { color: #0F172A !important; }

            /* Signatures */
            .vc-signatures {
                display: flex !important;
                justify-content: space-between !important;
                padding: 0 8px !important;
                margin-top: 6px !important;
            }
            .vc-sig-box {
                text-align: center !important;
                min-width: 70px !important;
            }
            .vc-sig-line {
                border-top: 1pt solid #1E3A8A !important;
                margin-top: 20px !important;
                padding-top: 2px !important;
            }
            .vc-sig-label {
                font-size: 8px !important;
                font-weight: 700 !important;
                color: #1E3A8A !important;
            }

            /* Footer */
            .vc-footer {
                margin-top: auto !important;
                display: flex !important;
                justify-content: space-between !important;
                align-items: center !important;
                border-top: 0.5pt solid #D4AF37 !important;
                padding-top: 2px !important;
                font-size: 6px !important;
                color: #9CA3AF !important;
            }
            .vc-footer-brand { color: #D4AF37 !important; font-weight: 700 !important; font-size: 7px !important; }

            .tabular { font-variant-numeric: tabular-nums; font-family: 'Arial', sans-serif; letter-spacing: 0.5px; }
        }

        /* Screen styles */
        @media screen {
            .vc {
                max-width: 800px;
                margin: 0 auto;
                padding: 24px;
                font-family: 'Tajawal', 'Cairo', sans-serif;
                color: #0F172A;
                border: 1px solid #E5E7EB;
                border-radius: 8px;
                background: white;
            }
            .vc-header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #1E3A8A; padding-bottom: 12px; margin-bottom: 16px; }
            .vc-brand-name { font-size: 20px; font-weight: 900; color: #0F172A; margin: 0; }
            .vc-brand-sub { font-size: 11px; color: #6B7280; margin: 2px 0; }
            .vc-logo { height: 50px; width: auto; }
            .vc-title-box { text-align: center; background: linear-gradient(135deg, #1E3A8A, #0F172A); color: white; padding: 8px 24px; border-radius: 6px; border: 2px solid #D4AF37; }
            .vc-title { font-size: 22px; font-weight: 900; color: #D4AF37; margin: 0; }
            .vc-title-en { font-size: 10px; color: #93C5FD; letter-spacing: 2px; text-transform: uppercase; }
            .vc-title-method { font-size: 13px; color: white; font-weight: 700; margin-top: 2px; }
            .vc-info-row { display: flex; gap: 0; margin-bottom: 12px; border: 1px solid #1E3A8A; border-radius: 4px; overflow: hidden; }
            .vc-field { flex: 1; display: flex; border-left: 1px solid #CBD5E1; }
            .vc-field:last-child { border-left: none; }
            .vc-field-label { background: #EFF6FF; padding: 6px 8px; font-size: 11px; font-weight: 700; color: #1E3A8A; white-space: nowrap; display: flex; align-items: center; border-left: 1px solid #CBD5E1; min-width: 80px; }
            .vc-field-value { padding: 6px 8px; font-size: 13px; font-weight: 700; color: #0F172A; display: flex; align-items: center; flex: 1; }
            .vc-party-row { display: flex; border: 1px solid #1E3A8A; border-radius: 4px; margin-bottom: 12px; overflow: hidden; }
            .vc-party-label { background: #EFF6FF; padding: 8px 12px; font-size: 12px; font-weight: 700; color: #1E3A8A; white-space: nowrap; display: flex; align-items: center; border-left: 1px solid #CBD5E1; }
            .vc-party-value { padding: 8px 12px; font-size: 14px; font-weight: 800; color: #0F172A; display: flex; align-items: center; flex: 1; }
            .vc-amount-row { display: flex; border: 2px solid #1E3A8A; border-radius: 4px; margin-bottom: 12px; overflow: hidden; background: #FEFCE8; }
            .vc-amount-label { background: #1E3A8A; padding: 8px 12px; font-size: 12px; font-weight: 700; color: #D4AF37; white-space: nowrap; display: flex; align-items: center; }
            .vc-amount-words { padding: 8px 12px; font-size: 14px; font-weight: 800; color: #0F172A; display: flex; align-items: center; flex: 1; }
            .vc-amount-number { background: #1E3A8A; padding: 8px 12px; font-size: 18px; font-weight: 900; color: #D4AF37; display: flex; align-items: center; gap: 6px; font-family: Arial, sans-serif; }
            .vc-amount-currency { font-size: 12px; color: #93C5FD; font-weight: 600; }
            .vc-account-label { font-size: 13px; font-weight: 800; color: #1E3A8A; margin-bottom: 6px; padding-right: 4px; }
            .vc-table { width: 100%; border-collapse: collapse; margin-bottom: 12px; border: 1px solid #1E3A8A; }
            .vc-table th { background: #1E3A8A; color: white; padding: 6px 8px; font-weight: 700; font-size: 11px; text-align: center; border: 1px solid #1E3A8A; }
            .vc-table td { padding: 6px 8px; font-size: 12px; font-weight: 600; border: 1px solid #CBD5E1; color: #0F172A; text-align: center; }
            .vc-table tr:nth-child(even) td { background: #F8FAFC; }
            .vc-table tfoot td { background: #0F172A; color: #D4AF37; font-weight: 800; border: 1px solid #1E3A8A; }
            .vc-entry-info { font-size: 12px; color: #4B5563; margin-bottom: 12px; }
            .vc-entry-info strong { color: #0F172A; }
            .vc-signatures { display: flex; justify-content: space-between; padding: 0 24px; margin-top: 24px; }
            .vc-sig-box { text-align: center; min-width: 120px; }
            .vc-sig-line { border-top: 1px solid #1E3A8A; margin-top: 40px; padding-top: 4px; }
            .vc-sig-label { font-size: 12px; font-weight: 700; color: #1E3A8A; }
            .vc-footer { margin-top: 16px; display: flex; justify-content: space-between; align-items: center; border-top: 1px solid #D4AF37; padding-top: 6px; font-size: 10px; color: #9CA3AF; }
            .vc-footer-brand { color: #D4AF37; font-weight: 700; font-size: 11px; }
            .tabular { font-variant-numeric: tabular-nums; font-family: Arial, sans-serif; }
        }
      `}</style>

      <div className="vc" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }}>

        {/* ═══ HEADER ═══ */}
        <div className="vc-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {brand?.logoUrl && (
              <img src={brand.logoUrl} alt="Logo" className="vc-logo" />
            )}
            <div>
              <h1 className="vc-brand-name">{brand?.name || AZTA_IDENTITY.tradeNameAr}</h1>
              {brand?.address && <div className="vc-brand-sub">{brand.address}</div>}
              {brand?.contactNumber && <div className="vc-brand-sub" dir="ltr">TEL: {brand.contactNumber}</div>}
            </div>
          </div>
          <div className="vc-title-box">
            <div className="vc-title">{voucherTitle}</div>
            <div className="vc-title-en">{voucherSubTitle}</div>
            {!isJournal && <div className="vc-title-method">/ {payMethodLabel}</div>}
          </div>
        </div>

        {/* ═══ INFO FIELDS ROW ═══ */}
        <div className="vc-info-row">
          <div className="vc-field">
            <div className="vc-field-label">رقم السند</div>
            <div className="vc-field-value tabular" dir="ltr">{data.voucherNumber}</div>
          </div>
          <div className="vc-field">
            <div className="vc-field-label">تاريخ السند</div>
            <div className="vc-field-value tabular" dir="ltr">{formattedDate}</div>
          </div>
          <div className="vc-field">
            <div className="vc-field-label">التاريخ الهجري</div>
            <div className="vc-field-value tabular" dir="ltr">{formattedHijriDate || '—'}</div>
          </div>
        </div>

        <div className="vc-info-row">
          <div className="vc-field">
            <div className="vc-field-label">{isJournal ? 'رقم المرجع' : 'اسم الصندوق'}</div>
            <div className="vc-field-value">{isJournal ? (data.referenceId || '—') : (data.shiftName || `صندوق${shiftNo ? ` ${shiftNo}` : ''}`)}</div>
          </div>
          <div className="vc-field">
            <div className="vc-field-label">{isJournal ? 'المرجع' : 'رقم الصندوق'}</div>
            <div className="vc-field-value tabular" dir="ltr">{isJournal ? (data.referenceId || '—') : (shiftNo || '—')}</div>
          </div>
          <div className="vc-field">
            <div className="vc-field-label">رقم المرجع</div>
            <div className="vc-field-value tabular" dir="ltr">{data.paymentReferenceNumber || data.referenceId || '—'}</div>
          </div>
        </div>

        {/* ═══ PARTY LINE ═══ */}
        {!isJournal && (
          <div className="vc-party-row">
            <div className="vc-party-label">
              {isPayment ? 'يصرف للسيد / السادة' : 'استلمنا من السيد / السادة'}
            </div>
            <div className="vc-party-value" style={{ borderLeft: '0.5pt solid #CBD5E1' }}>
              {cleanName(data.partyName || data.receivedBy || '—')}
              {data.senderPhone && <span style={{ marginRight: 8, fontSize: '8px', color: '#6B7280' }} dir="ltr">{data.senderPhone}</span>}
            </div>
          </div>
        )}

        {/* ═══ AMOUNT ROW ═══ */}
        {!isJournal && (
          <div className="vc-amount-row">
            <div className="vc-amount-number">
              <span className="vc-amount-currency">{currency}</span>
              <span className="tabular">{fmt(data.amount)}</span>
            </div>
            <div className="vc-amount-label">مبلغ وقدره</div>
            <div className="vc-amount-words">{data.amountWords || '—'} فقط لا غير</div>
          </div>
        )}

        {/* ═══ ACCOUNT LABEL ═══ */}
        <div className="vc-account-label">
          {isJournal ? 'تفاصيل القيد | Journal Lines' : (isPayment ? 'يخصم من حساب | Debit Account' : 'يقيد إلى حساب | Credit Account')}
        </div>

        {/* ═══ TABLE ═══ */}
        <table className="vc-table">
          <thead>
            {isJournal ? (
              <>
                <tr>
                  <th rowSpan={2}>رقم المركز</th>
                  <th colSpan={2} style={{ background: '#1e40af' }}>العملة الأجنبية</th>
                  <th colSpan={2}>العملة المحلية</th>
                  <th rowSpan={2}>البيان</th>
                  <th rowSpan={2}>العملة</th>
                  <th rowSpan={2}>اسم الحساب</th>
                  <th rowSpan={2}>رقم الحساب</th>
                  <th rowSpan={2}>م</th>
                </tr>
                <tr>
                  <th style={{ background: '#0F172A' }}>دائن</th>
                  <th style={{ background: '#0F172A' }}>مدين</th>
                  <th>دائن</th>
                  <th>مدين</th>
                </tr>
              </>
            ) : (
              <tr>
                <th>رقم الحساب</th>
                <th>العملة</th>
                <th>حساب التحليل</th>
                <th style={{ textAlign: 'right' }}>اسم الحساب</th>
                <th style={{ textAlign: 'right' }}>البيان</th>
                <th>المبلغ</th>
                <th>رقم المركز</th>
                <th>رقم المرجع</th>
              </tr>
            )}
          </thead>
          <tbody>
            {linesToRender.length === 0 ? (
              <tr>
                <td colSpan={isJournal ? 10 : 8} style={{ textAlign: 'center', color: '#9CA3AF', padding: 12 }}>لا توجد تفاصيل</td>
              </tr>
            ) : (
              linesToRender.map((l, idx) => (
                <tr key={idx}>
                  {isJournal ? (
                    <>
                      <td className="tabular">{l.costCenterNo || '—'}</td>
                      <td className="tabular" style={{ color: '#1E40AF' }}>{fmt(l.foreignCredit)}</td>
                      <td className="tabular" style={{ color: '#1E40AF' }}>{fmt(l.foreignDebit)}</td>
                      <td className="tabular">{fmt(l.credit)}</td>
                      <td className="tabular">{fmt(l.debit)}</td>
                      <td style={{ textAlign: 'right' }}>{l.memo || data.memo || '—'}</td>
                      <td className="tabular">{l.currency || currency}</td>
                      <td style={{ textAlign: 'right', fontWeight: 700 }}>{l.accountName}</td>
                      <td className="tabular" style={{ fontFamily: 'monospace' }}>{l.accountCode}</td>
                      <td className="tabular" style={{ color: '#9CA3AF' }}>{l.recordNo || (idx + 1)}</td>
                    </>
                  ) : (
                    <>
                      <td className="tabular" style={{ fontFamily: 'monospace' }}>{l.accountCode}</td>
                      <td className="tabular">{l.currency || currency}</td>
                      <td className="tabular">{l.analyticalAccount || l.costCenterNo || '—'}</td>
                      <td style={{ textAlign: 'right', fontWeight: 700 }}>{l.accountName}</td>
                      <td style={{ textAlign: 'right' }}>{l.memo || data.memo || '—'}</td>
                      <td className="tabular" style={{ fontWeight: 800 }}>{fmt(l.credit > 0 ? l.credit : l.debit)}</td>
                      <td className="tabular">{l.costCenterNo || brand?.branchCode || '—'}</td>
                      <td className="tabular">{l.referenceNo || '—'}</td>
                    </>
                  )}
                </tr>
              ))
            )}
            {/* Fill empty rows for visual consistency */}
            {Array.from({ length: Math.max(0, 3 - linesToRender.length) }).map((_, idx) => (
              <tr key={`fill-${idx}`}>
                {Array.from({ length: isJournal ? 10 : 8 }).map((_, ci) => (
                  <td key={ci}>&nbsp;</td>
                ))}
              </tr>
            ))}
          </tbody>
          {isJournal && (
            <tfoot>
              <tr>
                <td colSpan={3} style={{ textAlign: 'left', fontWeight: 800, fontSize: 10 }}>الإجمالي TOTAL</td>
                <td className="tabular">{fmt(totalCredit)}</td>
                <td className="tabular">{fmt(totalDebit)}</td>
                <td colSpan={5}></td>
              </tr>
            </tfoot>
          )}
        </table>

        {/* ═══ ENTRY INFO ═══ */}
        <div className="vc-entry-info">
          مدخل السجل : <strong>{cleanName(data.createdBy || data.receivedBy || AZTA_IDENTITY.tradeNameAr)}</strong>
          {brand?.branchCode && <span style={{ marginRight: 16 }}>مركز التكلفة : <strong>{brand.branchCode}</strong></span>}
        </div>

        {/* ═══ SIGNATURES ═══ */}
        <div className="vc-signatures">
          <div className="vc-sig-box">
            <div className="vc-sig-line">
              <div className="vc-sig-label">{isPayment ? 'المستلم' : 'الصندوق'}</div>
            </div>
          </div>
          <div className="vc-sig-box">
            <div className="vc-sig-line">
              <div className="vc-sig-label">المحاسب</div>
            </div>
          </div>
          <div className="vc-sig-box">
            <div className="vc-sig-line">
              <div className="vc-sig-label">المدير المالي</div>
            </div>
          </div>
        </div>

        {/* ═══ FOOTER ═══ */}
        <div className="vc-footer">
          <span>{new Date().toLocaleString('en-GB')} طبع بواسطة: {cleanName(data.createdBy || 'النظام')}</span>
          <span className="vc-footer-brand">{AZTA_IDENTITY.tradeNameAr} — LICENSED SYSTEM</span>
          <span>1/1</span>
        </div>

      </div>
    </div>
  );
}
