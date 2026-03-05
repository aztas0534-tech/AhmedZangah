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

  // Filter lines to hide the "cash/bank" contra account from the customer on receipts/payments
  // If receipt: hide the line that increased cash (debit), show the credit line (customer/revenue)
  // If payment: hide the line that decreased cash (credit), show the debit line (supplier/expense)
  const displayLines = isJournal
    ? data.lines
    : data.lines.filter(l => {
      if (isReceipt) {
        return Number(l.credit) > 0; // Show who paid us (Credit)
      } else if (isPayment) {
        return Number(l.debit) > 0; // Show who we paid (Debit)
      }
      return true;
    });

  // Ensure there's at least one line if filtering went too far
  const linesToRender = displayLines.length > 0 ? displayLines : data.lines;

  // Format date safely
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

  const voucherTitle = isJournal ? 'قيد يومية' : (isReceipt ? 'سند قبض / نقداً' : (isPayment ? 'سند صرف / نقداً' : data.title));

  return (
    <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir="rtl">
      <style>{`
        @media print {
            @page { size: A4; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }

            .voucher-container { 
                width: 100% !important; 
                padding: 8mm 12mm !important;
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
                font-size: 15rem !important;
                font-weight: 900 !important;
                color: #D4AF37 !important;
                opacity: 0.03 !important;
                white-space: nowrap !important;
                pointer-events: none !important;
                z-index: 1 !important;
                letter-spacing: -2px !important;
            }

            /* ═══ THE CERTIFICATE FRAME (ULTRA LUXURY) ═══ */
            .voucher-container::before {
                content: '';
                position: absolute !important;
                top: 4mm; bottom: 4mm; left: 4mm; right: 4mm;
                border: 2pt solid #1E3A8A !important;
                pointer-events: none !important;
                z-index: 50 !important;
            }
            .voucher-container::after {
                content: '';
                position: absolute !important;
                top: 5mm; bottom: 5mm; left: 5mm; right: 5mm;
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
                padding-bottom: 4px !important;
                margin-bottom: 8px !important;
            }
            .brand-name { font-size: 24px !important; font-weight: 900 !important; letter-spacing: -0.5px !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 2px !important; }
            .invoice-title { font-size: 32px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #D4AF37 !important; line-height: 0.9 !important; }
            .title-sub { font-size: 9px !important; font-weight: 800 !important; letter-spacing: 2px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #D4AF37 !important; padding-top: 2px !important; margin-top: 2px !important; text-align: center !important; }
            
            /* ═══ INFO GRID ═══ */
            .info-grid {
                display: flex !important;
                justify-content: space-between !important;
                margin-bottom: 6px !important;
                background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important;
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
                margin-bottom: 6px !important;
            }
            .luxury-table th {
                background-color: #0F172A !important;
                color: #FFFFFF !important;
                padding: 4px 6px !important;
                font-weight: 600 !important;
                font-size: 11px !important;
                text-transform: uppercase !important;
                letter-spacing: 0.5px !important;
                border: none !important;
            }
            .luxury-table td {
                padding: 3px 4px !important;
                font-size: 11px !important;
                font-weight: 600 !important;
                border-bottom: 0.5pt solid #E5E7EB !important;
                color: #0F172A !important;
            }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
            .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }
            .luxury-table tfoot td { background-color: #0F172A !important; color: white !important; font-size: 12px !important; font-weight: 800 !important; border-top: 1.5pt solid #D4AF37 !important; }

            /* ═══ AMOUNT BOX ═══ */
            .amount-showcase {
                display: flex !important;
                align-items: center !important;
                background-color: #0F172A !important;
                color: #FFFFFF !important;
                padding: 6px 12px !important;
                border-radius: 4px !important;
                border-right: 4pt solid #D4AF37 !important;
                margin-bottom: 6px !important;
                page-break-inside: avoid !important;
            }
            .amount-val { font-size: 20px !important; font-weight: 900 !important; color: #D4AF37 !important; letter-spacing: 1px !important; }
            .amount-txt { font-size: 13px !important; font-weight: bold !important; flex: 1 !important; text-align: right !important; padding-right: 12px !important; color: #E2E8F0 !important; }

            /* ═══ FOOTER ═══ */
            .luxury-footer {
                margin-top: auto !important;
                text-align: center !important;
                font-size: 9px !important;
                color: #4B5563 !important;
                padding-top: 4px !important;
                page-break-inside: avoid !important;
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                gap: 2px !important;
            }
            .footer-line {
                width: 50px !important;
                height: 1pt !important;
                background-color: #D4AF37 !important;
                margin: 2px 0 !important;
            }
        }
      `}</style>

      <div className="voucher-container w-full mx-auto p-12 bg-[#FAFAFA] flex flex-col text-blue-950 print:p-0" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }}>

        <div className="luxury-watermark">{AZTA_IDENTITY.tradeNameAr}</div>

        {/* ▬▬▬ HEADER ▬▬▬ */}
        <div className="luxury-header relative z-10 flex flex-col md:flex-row justify-between items-center md:items-end gap-6 pb-6 mb-8 border-b-2 border-slate-900 print:pb-0 print:mb-0 print:border-none print:flex-row">
          <div className="flex items-center gap-6 print:gap-4">
            {brand?.logoUrl && (
              <div className="bg-white p-2 print:p-1 print:border print:border-slate-200 z-10">
                <img src={brand.logoUrl} alt="Logo" className="h-24 print:h-12 w-auto object-contain print:grayscale" />
              </div>
            )}
            <div className="flex flex-col justify-center">
              <h1 className="brand-name">
                {brand?.name || AZTA_IDENTITY.tradeNameAr}
                {(brand?.name || brand?.branchName) && brand?.name !== AZTA_IDENTITY.tradeNameAr && (
                  <span className="text-sm font-normal text-slate-500 mr-2 print:text-[7px] font-sans">({brand?.name || brand?.branchName})</span>
                )}
              </h1>
              <div className="mt-2 print:mt-1 flex gap-3 text-sm print:text-[5px] text-slate-600 font-bold">
                {brand?.address && <span dir="ltr">Add: <span className="font-mono text-blue-950">{brand.address}</span></span>}
                {brand?.contactNumber && <span dir="ltr">TEL: <span className="font-mono text-blue-950">{brand.contactNumber}</span></span>}
              </div>
            </div>
          </div>

          <div className="text-center md:text-left rtl:text-left flex flex-col items-center flex-shrink-0 z-10">
            <h2 className="invoice-title">{voucherTitle}</h2>
            <div className="title-sub">{isJournal ? 'JOURNAL VOUCHER' : isPayment ? 'PAYMENT VOUCHER' : 'RECEIPT VOUCHER'}</div>
          </div>
        </div>

        {/* ▬▬▬ INFO SECTION ▬▬▬ */}
        <div className="info-grid relative z-10 mb-8 print:mb-3">
          <div className="info-group">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">{isPayment ? 'يصرف للسيد/السادة | Pay To' : isJournal ? 'المرجع الرئيسي' : 'استلمنا من السيد/السادة | Received From'}</span>
              <span className="font-bold-value text-gold">{isJournal ? (data.referenceId || '—') : cleanName(data.partyName || data.receivedBy || '—')}</span>
            </div>
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">البيان | Memo</span>
              <span className="font-bold-value text-charcoal max-w-[200px] print:max-w-none">{data.memo || '—'}</span>
            </div>
          </div>

          <div className="info-group border-r border-slate-300 pr-4 print:border-l print:border-r-0 print:border-[#E5E7EB] print:pl-4 print:pr-0">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">رقم السند | Voucher No.</span>
              <span className="font-bold-value font-mono text-charcoal" dir="ltr">#{data.voucherNumber}</span>
            </div>
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">التاريخ الميلادي | Date</span>
              <span className="font-bold-value font-mono tabular" dir="ltr">{formattedDate}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">التاريخ الهجري | Hijri</span>
              <span className="font-bold-value font-mono tabular" dir="ltr">{formattedHijriDate || '—'}</span>
            </div>
          </div>

          <div className="info-group border-r border-slate-300 pr-4 print:border-l print:border-r-0 print:border-[#E5E7EB] print:pl-4 print:pr-0">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">مركز التكلفة | Cost Center</span>
              <span className="font-bold-value text-charcoal">{brand?.branchCode || '—'}</span>
            </div>
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">الصندوق | Cash/Bank Shift</span>
              <span className="font-bold-value text-charcoal tabular" dir="ltr">{data.shiftName || shiftNo ? `${data.shiftName || ''} (${shiftNo || ''})`.trim() : '—'}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">مدخل السجل | Creator</span>
              <span className="font-bold-value text-charcoal">{cleanName(data.createdBy || data.receivedBy || AZTA_IDENTITY.tradeNameAr)}</span>
            </div>
          </div>
        </div>

        {/* ▬▬▬ AMOUNT SHOWCASE ▬▬▬ */}
        {!isJournal && (
          <div className="amount-showcase relative z-10 w-full mb-8 print:mb-4">
            <div className="flex gap-2 items-center">
              <span className="font-thin-label text-slate-300 mt-1">{currency}</span>
              <span className="amount-val tabular">{fmt(data.amount)}</span>
            </div>
            <div className="amount-txt">مبلغ وقدره: {data.amountWords || '—'}</div>
            <div className="font-thin-label text-slate-400 mt-1 border-r border-slate-600 pr-2">فقط لا غير</div>
          </div>
        )}

        {/* ▬▬▬ TABLE ▬▬▬ */}
        <div className="relative z-10 w-full overflow-hidden mb-8 print:mb-3">
          <div className="text-right font-bold text-[13px] mb-1 text-blue-950">
            {isJournal ? null : (isPayment ? 'يخصم من حساب | Debit Account' : 'يقيد إلى حساب | Credit Account')}
          </div>
          <table className="luxury-table text-right print:w-full">
            <thead>
              {isJournal ? (
                <>
                  <tr>
                    <th rowSpan={2} className="text-center">المركز</th>
                    <th colSpan={2} className="text-center bg-blue-900 border-x border-slate-700">العملة الأجنبية</th>
                    <th colSpan={2} className="text-center">العملة المحلية</th>
                    <th rowSpan={2} className="text-right">البيان</th>
                    <th rowSpan={2} className="text-center">العملة</th>
                    <th rowSpan={2} className="text-right">اسم الحساب</th>
                    <th rowSpan={2} className="text-center">رقم الحساب</th>
                    <th rowSpan={2} className="text-center w-8">م</th>
                  </tr>
                  <tr>
                    <th className="text-center bg-blue-950 border-r border-slate-700 text-[9px]">دائن</th>
                    <th className="text-center bg-blue-950 border-l border-slate-700 text-[9px]">مدين</th>
                    <th className="text-center text-[9px]">دائن</th>
                    <th className="text-center text-[9px]">مدين</th>
                  </tr>
                </>
              ) : (
                <tr>
                  <th className="text-center w-8 print:w-6">م</th>
                  <th className="text-right print:w-[45%]">البيان DESCRIPTION</th>
                  <th className="text-center print:w-[20%]">المبلغ AMOUNT</th>
                  <th className="text-center print:w-[15%]">المركز C.C</th>
                  <th className="text-center print:w-[15%]">المرجع REF</th>
                </tr>
              )}
            </thead>
            <tbody>
              {linesToRender.length === 0 ? (
                <tr>
                  <td colSpan={isJournal ? 11 : 5} className="py-4 text-center text-slate-400">لا توجد تفاصيل خطوط</td>
                </tr>
              ) : (
                linesToRender.map((l, idx) => (
                  <tr key={idx} style={{ pageBreakInside: 'avoid' }}>
                    {isJournal ? (
                      <>
                        <td className="text-center tabular font-thin-label text-slate-600">{l.costCenterNo || '—'}</td>
                        <td className="text-center tabular font-bold-value text-blue-800">{fmt(l.foreignCredit)}</td>
                        <td className="text-center tabular font-bold-value text-blue-800">{fmt(l.foreignDebit)}</td>
                        <td className="text-center tabular font-bold-value text-charcoal">{fmt(l.credit)}</td>
                        <td className="text-center tabular font-bold-value text-charcoal">{fmt(l.debit)}</td>
                        <td className="text-right font-bold-value text-charcoal">{l.memo || data.memo || '—'}</td>
                        <td className="text-center tabular font-thin-label">{l.currency || currency}</td>
                        <td className="text-right font-bold-value text-charcoal">{l.accountName}</td>
                        <td className="text-center tabular font-mono font-thin-label text-charcoal">{l.accountCode}</td>
                        <td className="text-center font-mono font-thin-label text-slate-400">{l.recordNo || (idx + 1)}</td>
                      </>
                    ) : (
                      <>
                        <td className="text-center font-mono font-thin-label text-slate-400">{idx + 1}</td>
                        <td className="font-bold-value text-blue-950">{l.memo || data.memo || '—'}</td>
                        <td className="text-center tabular font-mono font-bold-value text-charcoal">{fmt(l.credit > 0 ? l.credit : l.debit)}</td>
                        <td className="text-center font-bold-value text-slate-600">{l.costCenterNo || brand?.branchCode || '—'}</td>
                        <td className="text-center font-mono font-thin-label text-charcoal">{l.referenceNo || '—'}</td>
                      </>
                    )}
                  </tr>
                ))
              )}
              {Array.from({ length: Math.max(0, 3 - linesToRender.length) }).map((_, idx) => (
                <tr key={`fill-${idx}`}>
                  {isJournal ? (
                    <><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></>
                  ) : (
                    <><td></td><td></td><td></td><td></td><td></td></>
                  )}
                </tr>
              ))}
            </tbody>
            {isJournal && (
              <tfoot>
                <tr>
                  <td colSpan={3} className="text-left font-bold-value bg-blue-950 text-white p-2">الإجمالي TOTAL:</td>
                  <td className="text-center font-bold tabular text-gold">{fmt(totalCredit)}</td>
                  <td className="text-center font-bold tabular text-gold">{fmt(totalDebit)}</td>
                  <td colSpan={5} className="bg-blue-950"></td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>

        {/* ▬▬▬ LEGAL & SIGNATURES ▬▬▬ */}
        <div className="relative z-10 w-full mt-8 print:mt-4">
          <div className="flex justify-between items-end px-12 print:px-6">
            <div className="text-center w-32 print:w-24">
              <div className="border-t border-blue-900 print:border-blue-900 pt-1.5">
                <span className="font-thin-label block text-blue-950 font-bold">{isPayment ? 'المستلم | Receiver' : 'المقر بما فيه | Acknowledgement'}</span>
              </div>
            </div>
            <div className="text-center w-32 print:w-24">
              <div className="border-t border-blue-900 print:border-blue-900 pt-1.5">
                <span className="font-thin-label block text-blue-950 font-bold">المحاسب | Accountant</span>
              </div>
            </div>
            <div className="text-center w-32 print:w-24">
              <div className="border-t border-blue-900 print:border-blue-900 pt-1.5">
                <span className="font-thin-label block text-blue-950 font-bold">المدير المالي | Fin. Manager</span>
              </div>
            </div>
          </div>
        </div>

        {/* ▬▬▬ FOOTER ▬▬▬ */}
        <div className="luxury-footer relative z-10 w-full font-mono mt-auto pt-4">
          <div className="footer-line"></div>
          <div className="font-bold-value text-gold mb-1 print:mb-0.5 mt-1 font-sans tracking-wide">نموذج نظام مرخص — LICENSED SYSTEM FORM</div>
          <div className="flex justify-center gap-4 text-slate-400 font-sans">
            <span>{new Date().toLocaleString('en-GB')}</span>
            <span>طبع بواسطة: {cleanName(data.createdBy || 'النظام')}</span>
          </div>
        </div>

      </div>
    </div>
  );
}
