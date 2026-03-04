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

export default function PrintableVoucherBase(props: { data: VoucherData; brand?: Brand }) {
  const { data, brand } = props;
  const isJournal = data.title.includes('قيد يومية') || data.title.includes('JV');
  const isReceipt = data.title.includes('سند قبض');
  const isPayment = data.title.includes('سند صرف');

  const totalDebit = data.lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const totalCredit = data.lines.reduce((s, l) => s + Number(l.credit || 0), 0);

  // Format date safely
  const formattedDate = new Date(data.date).toLocaleDateString('en-GB');
  const formattedHijriDate = (() => {
    try {
      return new Intl.DateTimeFormat('ar-SA-u-nu-latn-ca-islamic', { day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(data.date));
    } catch {
      return '';
    }
  })();

  const currency = data.currency?.toUpperCase() || '—';
  const shiftNo = (() => {
    const n = data.shiftNumber;
    if (typeof n === 'number' && Number.isFinite(n) && n > 0) return String(Math.trunc(n));
    const id = String(data.shiftId || '').trim();
    if (!id) return '';
    const compact = id.replace(/-/g, '').toUpperCase();
    return compact.slice(-6);
  })();
  return (
    <div className="voucher-container w-full bg-white text-black p-4 text-sm" dir="rtl" style={{ maxWidth: '210mm', margin: '0 auto', fontFamily: 'Tajawal, Cairo, sans-serif' }}>
      <style>{`
        @media print {
          @page { size: A4; margin: 10mm; }
          body { -webkit-print-color-adjust: exact; print-color-adjust: exact; background: white; }
          .voucher-container { border: none !important; margin: 0 !important; width: 100% !important; padding: 0 !important; }
        }
        .outer-border { border: 2px solid black; padding: 4px; border-radius: 8px; }
        .inner-border { border: 1px solid black; padding: 10px; border-radius: 4px; }
        .table-borders th, .table-borders td { border: 1px solid black; padding: 4px 6px; text-align: center; font-size: 11px; }
        .table-borders th { background-color: #f3f4f6; font-weight: bold; }
        .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; }
        .print-title { background-color: #e5e7eb; border: 1px solid black; border-radius: 20px; padding: 4px 30px; font-size: 18px; font-weight: bold; width: fit-content; margin: 0 auto; margin-top: -10px; }
      `}</style>

      <div className="outer-border">
        <div className="inner-border min-h-[90vh] flex flex-col">

          {/* Header */}
          <div className="flex justify-between items-start border-b border-black pb-2 mb-4">
            {/* Left - English Info */}
            <div className="text-left" style={{ width: '30%', fontSize: '11px', lineHeight: '1.4' }}>
              <div className="font-bold text-[13px]">{brand?.name || AZTA_IDENTITY.tradeNameAr}</div>
              {brand?.address && <div>{brand.address}</div>}
              {brand?.contactNumber && <div>{brand.contactNumber}</div>}
            </div>

            {/* Center - Logo */}
            <div className="flex flex-col items-center justify-center" style={{ width: '40%' }}>
              {brand?.logoUrl ? (
                <img src={brand.logoUrl} alt="Logo" style={{ height: 60, objectFit: 'contain' }} />
              ) : (
                <div style={{ height: 60, width: 60, borderRadius: '50%', border: '1px solid black', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: '24px', fontWeight: 'bold' }}>
                  A
                </div>
              )}
            </div>

            {/* Right - Arabic Info */}
            <div className="text-right" style={{ width: '30%', fontSize: '11px', lineHeight: '1.4' }}>
              <div className="font-bold text-[13px]">{AZTA_IDENTITY.tradeNameAr}</div>
              {(brand?.name || brand?.branchName) && brand?.name !== AZTA_IDENTITY.tradeNameAr && (
                <div className="font-bold">{brand?.name || brand?.branchName}</div>
              )}
              {brand?.address && <div>{brand.address}</div>}
              {brand?.contactNumber && <div dir="ltr" className="text-right">{brand.contactNumber}</div>}
            </div>
          </div>

          <div className="relative mb-6">
            <div className="print-title">
              {isJournal ? 'قيود اليومية' : (isReceipt ? 'سند قبض / نقداً' : (isPayment ? 'سند صرف / نقداً' : data.title))}
            </div>
          </div>

          {/* Type specific top sections */}
          {!isJournal ? (
            // Receipt / Payment Top Section
            <div className="flex justify-between items-start mb-4">
              {/* Left Block */}
              <div className="flex flex-col gap-1" style={{ width: '30%' }}>
                <div className="flex">
                  <div className="w-1/2 labelBoxStyles border border-black bg-gray-100 text-center text-[11px] font-bold py-1 px-2">رقم الصندوق</div>
                  <div className="w-1/2 headerBoxStyles border border-black text-center text-[12px] font-bold py-1 px-2">{shiftNo || '1'}</div>
                </div>
                <div className="flex">
                  <div className="w-1/2 labelBoxStyles border border-black bg-gray-100 text-center text-[11px] font-bold py-1 px-2">اسم الصندوق</div>
                  <div className="w-1/2 headerBoxStyles border border-black text-center text-[12px] font-bold py-1 px-2">صندوق 1</div>
                </div>
              </div>

              {/* Right Block */}
              <div className="flex flex-col gap-1" style={{ width: '30%' }}>
                <div className="flex">
                  <div className="w-1/3 labelBoxStyles border border-black bg-gray-100 text-center text-[11px] font-bold py-1 px-2">رقم السند</div>
                  <div className="w-2/3 headerBoxStyles border border-black text-center text-[12px] font-bold py-1 px-2 tabular">{data.voucherNumber}</div>
                </div>
                <div className="flex">
                  <div className="w-1/3 labelBoxStyles border border-black bg-gray-100 text-center text-[11px] font-bold py-1 px-2">تاريخ السند</div>
                  <div className="w-1/3 headerBoxStyles border border-black text-center text-[12px] font-bold py-1 px-2 tabular">{formattedHijriDate || '—'}</div>
                  <div className="w-1/3 headerBoxStyles border border-black text-center text-[12px] font-bold py-1 px-2 tabular">{formattedDate}</div>
                </div>
                <div className="flex">
                  <div className="w-1/3 labelBoxStyles border border-black bg-gray-100 text-center text-[11px] font-bold py-1 px-2">رقم المرجع</div>
                  <div className="w-2/3 headerBoxStyles border border-black text-center text-[12px] font-bold py-1 px-2 tabular">{data.referenceId || '—'}</div>
                </div>
              </div>
            </div>
          ) : (
            // Journal Top Section
            <div className="grid grid-cols-4 gap-0 border border-black mb-4 bg-gray-50 text-[11px]">
              <div className="col-span-1 border-l border-black flex items-center px-2 py-1">نوع الوثيقة: قيد يومية</div>
              <div className="col-span-1 border-l border-black flex items-center px-2 py-1">رقم القيد: <span className="font-bold mr-2">{data.voucherNumber}</span></div>
              <div className="col-span-1 border-l border-black flex items-center px-2 py-1">تاريخ السند: <span className="font-bold mr-2 tabular">{formattedDate}</span></div>
              <div className="col-span-1 flex items-center px-2 py-1">رقم المرجع: <span className="font-bold mr-2 tabular">{data.referenceId || '—'}</span></div>

              <div className="col-span-2 border-t border-l border-black flex items-center px-2 py-1 text-[11px]">المستفيد: <span className="mr-2">{data.partyName || '—'}</span></div>
              <div className="col-span-1 border-t border-l border-black flex items-center px-2 py-1 text-[11px]">المستلم: <span className="mr-2">{data.receivedBy || '—'}</span></div>
              <div className="col-span-1 border-t border-black flex items-center px-2 py-1 text-[11px]">عدد المرفقات: <span className="mr-2 tabular">{data.attachmentsCount || '0'}</span></div>
            </div>
          )}

          {/* Details (Receipt/Payment only) */}
          {!isJournal && (
            <div className="flex flex-col mb-4 text-[12px] border border-black bg-blue-50/20">
              <div className="flex border-b border-black">
                <div className="w-[15%] rightBox p-1 font-bold border-l border-black bg-gray-100">المحترم</div>
                <div className="w-[85%] rightBox p-1">استلمنا من السيد / السادة: <span className="font-bold mr-2">{data.partyName || data.receivedBy || '—'}</span></div>
              </div>
              <div className="flex border-b border-black">
                <div className="w-[15%] rightBox p-1 font-bold border-l border-black bg-blue-100 flex items-center justify-between px-2">
                  <span className="tabular">{currency}</span>
                  <span className="tabular">{fmt(data.amount)}</span>
                </div>
                <div className="w-[85%] rightBox p-1 bg-blue-50 flex items-center">
                  <span className="ml-2">مبلغ وقدره:</span> <span className="font-bold">{data.amountWords || '—'}</span>
                </div>
              </div>
              <div className="flex">
                <div className="w-full rightBox p-1 font-bold">يقيد الى حساب: <span className="font-normal mr-2">{data.toAccount || data.lines[data.lines.length - 1]?.accountName || '—'}</span></div>
              </div>
            </div>
          )}

          {/* Main Table */}
          <table className="w-full table-borders mb-2">
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
                  <th style={{ width: '10%' }}>رقم المرجع</th>
                  <th style={{ width: '15%' }}>رقم المركز</th>
                  <th style={{ width: '15%' }}>المبلغ</th>
                  <th style={{ width: '25%' }}>البيان</th>
                  <th style={{ width: '20%' }}>اسم الحساب</th>
                  <th style={{ width: '8%' }}>الحساب التحليلي</th>
                  <th style={{ width: '5%' }}>العملة</th>
                  <th style={{ width: '10%' }}>رقم الحساب</th>
                </tr>
              )}
            </thead>
            <tbody>
              {data.lines.length === 0 ? (
                <tr>
                  <td colSpan={isJournal ? 11 : 8} className="py-4 text-gray-400">لا توجد تفاصيل خطوط</td>
                </tr>
              ) : (
                data.lines.map((l, idx) => (
                  <tr key={idx}>
                    {isJournal ? (
                      <>
                        <td className="tabular">{l.costCenterNo || '—'}</td>
                        <td className="tabular">{fmt(l.foreignCredit)}</td>
                        <td className="tabular">{fmt(l.foreignDebit)}</td>
                        <td className="tabular font-bold">{fmt(l.credit)}</td>
                        <td className="tabular font-bold">{fmt(l.debit)}</td>
                        <td className="text-right text-[10px]">{l.memo || data.memo || '—'}</td>
                        <td className="tabular">{l.currency || currency}</td>
                        <td className="text-right">{l.accountName}</td>
                        <td className="tabular">{l.analyticalAccount || '—'}</td>
                        <td className="tabular font-bold">{l.accountCode}</td>
                        <td className="tabular">{l.recordNo || (idx + 1)}</td>
                      </>
                    ) : (
                      <>
                        <td className="tabular">{l.referenceNo || '—'}</td>
                        <td className="tabular">{l.costCenterNo || brand?.branchCode || '—'}</td>
                        <td className="tabular font-bold text-[12px]">{fmt(l.credit > 0 ? l.credit : l.debit)}</td>
                        <td className="text-right text-[10px]">{l.memo || data.memo || '—'}</td>
                        <td className="text-right">{l.accountName}</td>
                        <td className="tabular">{l.analyticalAccount || '—'}</td>
                        <td className="tabular">{l.currency || currency}</td>
                        <td className="tabular font-bold">{l.accountCode}</td>
                      </>
                    )}
                  </tr>
                ))
              )}
              {/* Padding rows to make the table look full if lines are less than 5 */}
              {Array.from({ length: Math.max(0, 5 - data.lines.length) }).map((_, idx) => (
                <tr key={`fill-${idx}`}>
                  {isJournal ? (
                    <>
                      <td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td>
                    </>
                  ) : (
                    <>
                      <td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td><td>&nbsp;</td>
                    </>
                  )}
                </tr>
              ))}
            </tbody>
            {isJournal && (
              <tfoot className="border-t-[2px] border-black text-[12px]">
                <tr>
                  <td colSpan={3} className="text-left font-bold text-[12px] p-2 bg-gray-100">الإجمالي:</td>
                  <td className="font-bold text-[12px] tabular text-red-600">{fmt(totalCredit)}</td>
                  <td className="font-bold text-[12px] tabular text-red-600">{fmt(totalDebit)}</td>
                  <td colSpan={6} className="bg-gray-100"></td>
                </tr>
              </tfoot>
            )}
            {!isJournal && (
              <tfoot className="border-t border-black">
                {/* Only to close the table cleanly */}
              </tfoot>
            )}
          </table>

          {/* Spacer to push footers down */}
          <div className="flex-grow"></div>

          {/* Footer Signatures */}
          {isJournal ? (
            <div className="flex justify-between mt-8 border-t border-black pt-4 text-[11px] font-bold text-center px-4">
              <div className="flex-1 border-l border-black last:border-0 px-2 min-h-[40px] relative">
                <div className="absolute top-[-14px] right-0 bg-white px-1 mr-2 text-gray-500 font-normal">المختص</div>
              </div>
              <div className="flex-1 border-l border-black last:border-0 px-2 min-h-[40px] relative">
                <div className="absolute top-[-14px] right-0 bg-white px-1 mr-2 text-gray-500 font-normal">المحاسب</div>
              </div>
              <div className="flex-1 border-l border-black last:border-0 px-2 min-h-[40px] relative">
                <div className="absolute top-[-14px] right-0 bg-white px-1 mr-2 text-gray-500 font-normal">المراجع</div>
              </div>
              <div className="flex-1 border-l border-black last:border-0 px-2 min-h-[40px] relative">
                <div className="absolute top-[-14px] right-0 bg-white px-1 mr-2 text-gray-500 font-normal">المدير المالي</div>
              </div>
              <div className="flex-1 px-2 min-h-[40px] relative">
                <div className="absolute top-[-14px] right-0 bg-white px-1 mr-2 text-gray-500 font-normal">المدير العام</div>
              </div>
            </div>
          ) : (
            <div className="flex justify-between border-t border-black pt-2 text-[11px] font-bold text-center mt-6">
              <div className="w-1/3">المدير المالي<br /><br />______________________</div>
              <div className="w-1/3">الصندوق<br /><br />______________________</div>
              <div className="w-1/3">مدخل السجل : <span className="font-normal">{data.createdBy || data.receivedBy || brand?.name || AZTA_IDENTITY.tradeNameAr}</span></div>
            </div>
          )}

          {/* bottom metadata */}
          <div className="flex justify-between text-[9px] mt-4 text-gray-500 pt-1 border-t border-gray-300">
            <div dir="ltr" className="tabular">{new Date().toLocaleString('en-US')} :تاريخ التقرير </div>
            <div>{AZTA_IDENTITY.tradeNameAr} {(brand?.name && brand?.name !== AZTA_IDENTITY.tradeNameAr) ? ' - ' + brand?.name : ''}</div>
            <div className="tabular">1 / 1</div>
            <div>طبع بواسطة : <span className="font-bold">{data.createdBy || AZTA_IDENTITY.tradeNameAr}</span></div>
          </div>

        </div>
      </div>
    </div>
  );
}
