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
    <div className="voucher-container w-full bg-white text-black p-4 text-[13px]" dir="rtl" style={{ maxWidth: '210mm', minHeight: '297mm', margin: '0 auto', fontFamily: 'Tajawal, Cairo, sans-serif' }}>
      <style>{`
        @media print {
          @page { size: A4; margin: 10mm; }
          body { -webkit-print-color-adjust: exact; print-color-adjust: exact; background: white; }
          .voucher-container { border: none !important; margin: 0 !important; width: 100% !important; padding: 0 !important; }
        }
        .outer-border { border: 1px solid #000; padding: 2px; }
        .inner-border { border: 1px solid #000; padding: 8px; min-height: 95vh; display: flex; flex-direction: column; }
        
        .header-section { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 8px; padding-bottom: 8px; border-bottom: 2px solid #555; }
        .logo-area { width: 100px; height: 100px; display: flex; justify-content: center; align-items: center; }
        .logo-img { max-width: 100%; max-height: 100%; object-fit: contain; }
        
        .title-box { background-color: #cbe9ff; border: 1px solid #000; padding: 4px 60px; border-radius: 20px; font-size: 16px; font-weight: bold; text-align: center; width: fit-content; margin: -16px auto 16px auto; }
        
        .grid-header { display: flex; gap: 8px; margin-bottom: 4px; }
        .grid-cell { border: 1px solid #000; padding: 2px 6px; display: flex; align-items: center; font-size: 13px; font-weight: bold; }
        .grid-cell.label { width: 100px; }
        .grid-cell.value { flex: 1; text-align: center; }
        
        .info-row { display: flex; margin-bottom: 4px; border: 1px solid #000; }
        .info-label { padding: 4px 10px; font-weight: bold; white-space: nowrap; }
        .info-value { padding: 4px 10px; flex: 1; border-right: 1px solid #000; background-color: #f8fafc; font-weight: bold; }
        
        .amount-row { display: flex; margin-bottom: 8px; border: 1px solid #000; }
        .amount-box { width: 200px; background-color: #cbe9ff; display: flex; align-items: center; justify-content: flex-start; padding: 4px 12px; font-weight: bold; font-size: 15px; border-left: 1px solid #000; }
        .amount-words { flex: 1; background-color: #cbe9ff; padding: 4px 12px; font-weight: bold; font-size: 14px; display: flex; align-items: center; }
        
        .table-borders { width: 100%; border-collapse: collapse; margin-top: 4px; margin-bottom: 16px; border: 1px solid #000; }
        .table-borders th, .table-borders td { border: 1px solid #000; padding: 4px 6px; text-align: center; font-size: 12px; }
        .table-borders th { background-color: #cbe9ff; font-weight: bold; }
        .table-borders td { height: 26px; font-weight: bold; }
        .table-borders tbody tr:nth-child(even) { background-color: #f8fafc; }
        
        .tabular { font-variant-numeric: tabular-nums; font-family: 'Arial', sans-serif; letter-spacing: 0.5px; }

        .footer-sigs { display: flex; justify-content: space-between; border-top: 1px solid #000; margin-top: auto; padding-top: 16px; font-weight: bold; text-align: center; }
        .sig-box { width: 30%; font-size: 13px; }
        .sig-line { border-bottom: 1px solid #000; margin: 24px auto 8px auto; width: 60%; }
      `}</style>

      <div className="outer-border">
        <div className="inner-border">

          {/* Header */}
          <div className="header-section">
            <div className="flex flex-col" style={{ width: '35%', textAlign: 'left', direction: 'ltr' }}>
              <div className="font-bold text-[14px]">{brand?.name || AZTA_IDENTITY.tradeNameAr}</div>
              {brand?.address && <div className="text-[12px]">{brand.address}</div>}
              {brand?.contactNumber && <div className="text-[12px]">Tel: {brand.contactNumber}</div>}
            </div>

            <div className="logo-area">
              {brand?.logoUrl ? (
                <img src={brand.logoUrl} alt="Logo" className="logo-img" />
              ) : (
                <div style={{ width: 80, height: 80, borderRadius: '50%', border: '2px solid #1D4ED8', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: '24px', fontWeight: 'bold', color: '#1D4ED8' }}>
                  A
                </div>
              )}
            </div>

            <div className="flex flex-col" style={{ width: '35%', textAlign: 'right' }}>
              <div className="font-bold text-[14px]">الادارة العامه</div>
              <div className="font-bold text-[14px]">{AZTA_IDENTITY.tradeNameAr}</div>
              {(brand?.name || brand?.branchName) && brand?.name !== AZTA_IDENTITY.tradeNameAr && (
                <div className="font-bold text-[13px]">{brand?.name || brand?.branchName}</div>
              )}
              {brand?.address && <div className="text-[12px]">{brand.address}</div>}
              {brand?.contactNumber && <div className="text-[12px]" dir="ltr">{brand.contactNumber}</div>}
            </div>
          </div>

          <div className="title-box">
            {voucherTitle}
          </div>

          <div className="flex justify-between items-start mb-2">
            {/* Left side boxes */}
            <div className="flex flex-col w-[30%]">
              <div className="grid-header">
                <div className="grid-cell label">رقم الصندوق</div>
                <div className="grid-cell value tabular">{shiftNo || '1'}</div>
              </div>
              <div className="grid-header">
                <div className="grid-cell label">اسم الصندوق</div>
                <div className="grid-cell value tabular">صندوق 1</div>
              </div>
            </div>

            {/* Spacer */}
            <div className="w-[30%]"></div>

            {/* Right side boxes */}
            <div className="flex flex-col w-[35%]">
              <div className="grid-header">
                <div className="grid-cell label">رقم السند</div>
                <div className="grid-cell value tabular">{data.voucherNumber}</div>
              </div>
              <div className="grid-header">
                <div className="grid-cell label">تاريخ السند</div>
                <div className="grid-cell value tabular" style={{ fontSize: '11px' }}>{formattedHijriDate || '—'}</div>
                <div className="grid-cell value tabular" style={{ fontSize: '11px' }}>{formattedDate}</div>
              </div>
              <div className="grid-header">
                <div className="grid-cell label">رقم المرجع</div>
                <div className="grid-cell value tabular" style={{ fontSize: '11px', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{data.referenceId || '—'}</div>
              </div>
            </div>
          </div>

          <div className="info-row">
            <div className="info-label">{isPayment ? 'يصرف للسيد / السادة' : 'استلمنا من السيد / السادة'}</div>
            <div className="info-value">{cleanName(data.partyName || data.receivedBy || '—')} {data.memo ? ` /// ${data.memo}` : ''}</div>
            <div className="info-label border-r border-black" style={{ borderRight: '1px solid black' }}>المحترم</div>
          </div>

          <div className="amount-row">
            <div className="amount-box">
              <span className="ml-4 text-blue-900">{currency}</span>
              <span className="tabular">{fmt(data.amount)}</span>
            </div>
            <div className="amount-words">
              <span className="ml-2 font-normal">مبلغ وقدره</span> {data.amountWords || '—'}
            </div>
          </div>

          {isJournal ? null : (
            <div className="text-right font-bold text-[13px] mb-1">
              {isPayment ? 'يخصم من حساب' : 'يقيد إلى حساب'}
            </div>
          )}

          <table className="table-borders">
            <thead>
              {isJournal ? (
                <>
                  <tr>
                    <th rowSpan={2} style={{ width: '8%' }}>رقم المركز</th>
                    <th colSpan={2} style={{ width: '20%' }}>العملة الأجنبية</th>
                    <th colSpan={2} style={{ width: '20%' }}>العملة المحلية</th>
                    <th rowSpan={2} style={{ width: '18%' }}>البيان</th>
                    <th rowSpan={2} style={{ width: '6%' }}>العملة</th>
                    <th rowSpan={2} style={{ width: '15%' }}>اسم الحساب</th>
                    <th rowSpan={2} style={{ width: '8%' }}>الحساب التحليلي</th>
                    <th rowSpan={2} style={{ width: '8%' }}>رقم الحساب</th>
                    <th rowSpan={2} style={{ width: '5%' }}>رقم السجل</th>
                  </tr>
                  <tr>
                    <th className="bg-gray-50 border-t border-black">دائن</th>
                    <th className="bg-gray-50 border-t border-black">مدين</th>
                    <th className="bg-gray-50 border-t border-black">دائن</th>
                    <th className="bg-gray-50 border-t border-black">مدين</th>
                  </tr>
                </>
              ) : (
                <tr>
                  <th style={{ width: '12%' }}>رقم الحساب</th>
                  <th style={{ width: '6%' }}>العملة</th>
                  <th style={{ width: '8%' }}>الحساب التحليلي</th>
                  <th style={{ width: '20%' }}>اسم الحساب</th>
                  <th style={{ width: '25%' }}>البيان</th>
                  <th style={{ width: '15%' }}>المبلغ</th>
                  <th style={{ width: '15%' }}>رقم المركز</th>
                  <th style={{ width: '12%' }}>رقم المرجع</th>
                </tr>
              )}
            </thead>
            <tbody>
              {linesToRender.length === 0 ? (
                <tr>
                  <td colSpan={isJournal ? 11 : 8} className="py-4 text-gray-400">لا توجد تفاصيل خطوط</td>
                </tr>
              ) : (
                linesToRender.map((l, idx) => (
                  <tr key={idx}>
                    {isJournal ? (
                      <>
                        <td className="tabular">{l.costCenterNo || '—'}</td>
                        <td className="tabular">{fmt(l.foreignCredit)}</td>
                        <td className="tabular">{fmt(l.foreignDebit)}</td>
                        <td className="tabular">{fmt(l.credit)}</td>
                        <td className="tabular">{fmt(l.debit)}</td>
                        <td className="text-right text-[11px]">{l.memo || data.memo || '—'}</td>
                        <td className="tabular">{l.currency || currency}</td>
                        <td className="text-right">{l.accountName}</td>
                        <td className="tabular">{l.analyticalAccount || '—'}</td>
                        <td className="tabular">{l.accountCode}</td>
                        <td className="tabular">{l.recordNo || (idx + 1)}</td>
                      </>
                    ) : (
                      <>
                        <td className="tabular">{l.accountCode}</td>
                        <td className="tabular">{l.currency || currency}</td>
                        <td className="tabular">{l.analyticalAccount || '—'}</td>
                        <td className="text-right text-[12px] font-bold">{l.accountName}</td>
                        <td className="text-right text-[11px] font-normal">{l.memo || data.memo || '—'}</td>
                        <td className="tabular tabular-nums font-bold">{fmt(l.credit > 0 ? l.credit : l.debit)}</td>
                        <td className="tabular">{l.costCenterNo || brand?.branchCode || 'المركز 01001 الرئيسي'}</td>
                        <td className="tabular">{l.referenceNo || '—'}</td>
                      </>
                    )}
                  </tr>
                ))
              )}
              {/* Padding rows to ensure table always has at least 3 rows visually */}
              {Array.from({ length: Math.max(0, 3 - linesToRender.length) }).map((_, idx) => (
                <tr key={`fill-${idx}`}>
                  {isJournal ? (
                    <><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></>
                  ) : (
                    <><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></>
                  )}
                </tr>
              ))}
            </tbody>
            {isJournal && (
              <tfoot className="border-t-[2px] border-black">
                <tr>
                  <td colSpan={3} className="text-left font-bold p-2 bg-blue-50">الإجمالي:</td>
                  <td className="font-bold tabular text-red-600">{fmt(totalCredit)}</td>
                  <td className="font-bold tabular text-red-600">{fmt(totalDebit)}</td>
                  <td colSpan={6} className="bg-blue-50"></td>
                </tr>
              </tfoot>
            )}
          </table>

          {/* Footer Items */}
          <div className="flex font-bold text-[12px] mb-4 text-gray-700">
            <div className="w-[120px]">مدخل السجل: </div>
            <div>{cleanName(data.createdBy || data.receivedBy || AZTA_IDENTITY.tradeNameAr)}</div>
          </div>

          <div className="footer-sigs">
            <div className="sig-box">
              <div className="sig-line"></div>
              <div>المستلم</div>
            </div>
            <div className="sig-box">
              <div className="sig-line"></div>
              <div>المدير المالي</div>
            </div>
            <div className="sig-box">
              <div className="sig-line"></div>
              <div>الصندوق</div>
            </div>
          </div>

          <div className="flex justify-between items-center text-[10px] text-gray-500 mt-4 border-t border-black pt-2 w-full">
            <div className="flex gap-2 tabular" dir="ltr">
              <span>PM تاريخ التقرير :</span>
              <span>{new Date().toLocaleDateString('en-GB')}</span>
              <span>{new Date().toLocaleTimeString('en-US', { hour12: false })}</span>
            </div>
            <div className="tabular">1 / 1</div>
            <div>طبع بواسطة : <span className="font-bold">{cleanName(data.createdBy || 'النظام')}</span></div>
          </div>

        </div>
      </div>
    </div>
  );
}
