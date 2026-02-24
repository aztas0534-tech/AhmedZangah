import React from 'react';

type Brand = {
  name?: string;
  address?: string;
  contactNumber?: string;
  logoUrl?: string;
  branchName?: string;
  branchCode?: string;
};

type ReturnItem = {
  itemId: string;
  itemName: string;
  quantityBase: number;
  salesUnitQty?: number | null;
  uomCode?: string | null;
  unitPrice: number;
  total: number;
  reason?: string | null;
};

export type PrintableSalesReturnNoteData = {
  returnId: string;
  orderId: string;
  invoiceNumber?: string | null;
  returnDate: string;
  status?: string | null;
  customerName?: string | null;
  customerPhone?: string | null;
  reason?: string | null;
  refundMethod?: string | null;
  currency: string;
  returnSubtotal: number;
  taxRefund: number;
  totalRefund: number;
  items: ReturnItem[];
};

const fmtAmount = (n: number) => {
  try {
    return (Number.isFinite(n) ? n : 0).toLocaleString('ar-EG-u-nu-latn', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  } catch {
    return String(n);
  }
};

const fmtTime = (iso: string) => {
  try {
    return new Date(iso).toLocaleString('ar-EG-u-nu-latn');
  } catch {
    return iso;
  }
};

const methodLabel = (m?: string | null) => {
  const v = String(m || '').trim().toLowerCase();
  if (v === 'cash') return 'نقد';
  if (v === 'network') return 'شبكة';
  if (v === 'kuraimi') return 'كريمي';
  if (v === 'ar') return 'ذمم';
  if (v === 'store_credit') return 'رصيد عميل';
  return v || '—';
};

const PrintableSalesReturnNote: React.FC<{ data: PrintableSalesReturnNoteData; brand?: Brand }> = ({ data, brand }) => {
  const cur = String(data.currency || '').trim().toUpperCase() || 'YER';
  const title = 'إشعار مرتجع مبيعات (Credit Note)';
  const idShort = String(data.returnId || '').replace(/-/g, '').slice(-8).toUpperCase();
  const invoice = data.invoiceNumber ? String(data.invoiceNumber) : null;

  return (
    <div dir="rtl" className="bg-white text-black">
      <style>{`
        @media print {
          @page { size: A4; margin: 10mm; }
          body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        }
        .wrap { font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, "Noto Sans Arabic", sans-serif; }
        .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #e5e7eb; padding: 6px 8px; font-size: 12px; }
        th { background: #f3f4f6; text-align: right; }
      `}</style>

      <div className="wrap">
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, alignItems: 'flex-start' }}>
          <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
            {brand?.logoUrl ? <img src={brand.logoUrl} alt="" style={{ width: 56, height: 56, objectFit: 'contain' }} /> : null}
            <div>
              <div style={{ fontSize: 18, fontWeight: 800 }}>{brand?.name || ''}</div>
              {brand?.branchName ? <div style={{ fontSize: 12, color: '#374151' }}>{brand.branchName}{brand.branchCode ? ` (${brand.branchCode})` : ''}</div> : null}
              {brand?.address ? <div style={{ fontSize: 12, color: '#374151' }}>{brand.address}</div> : null}
              {brand?.contactNumber ? <div style={{ fontSize: 12, color: '#374151' }}>{brand.contactNumber}</div> : null}
            </div>
          </div>
          <div style={{ textAlign: 'left' }}>
            <div style={{ fontSize: 16, fontWeight: 800 }}>{title}</div>
            <div style={{ fontSize: 12, color: '#374151' }}>
              رقم الإشعار: <span className="mono">{idShort}</span>
            </div>
            <div style={{ fontSize: 12, color: '#374151' }}>
              التاريخ: <span className="mono">{fmtTime(data.returnDate)}</span>
            </div>
            {invoice ? (
              <div style={{ fontSize: 12, color: '#374151' }}>
                رقم الفاتورة: <span className="mono">{invoice}</span>
              </div>
            ) : null}
          </div>
        </div>

        <div style={{ marginTop: 16, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <div style={{ border: '1px solid #e5e7eb', borderRadius: 8, padding: 10 }}>
            <div style={{ fontWeight: 800, marginBottom: 6 }}>بيانات العميل</div>
            <div style={{ fontSize: 12 }}>الاسم: {data.customerName || '—'}</div>
            <div style={{ fontSize: 12 }}>الهاتف: <span className="mono">{data.customerPhone || '—'}</span></div>
            <div style={{ fontSize: 12 }}>الطلب: <span className="mono">{String(data.orderId || '').slice(-8)}</span></div>
          </div>
          <div style={{ border: '1px solid #e5e7eb', borderRadius: 8, padding: 10 }}>
            <div style={{ fontWeight: 800, marginBottom: 6 }}>بيانات المرتجع</div>
            <div style={{ fontSize: 12 }}>الحالة: {data.status || '—'}</div>
            <div style={{ fontSize: 12 }}>طريقة الإرجاع: {methodLabel(data.refundMethod)}</div>
            <div style={{ fontSize: 12 }}>السبب: {data.reason || '—'}</div>
          </div>
        </div>

        <div style={{ marginTop: 16 }}>
          <table>
            <thead>
              <tr>
                <th style={{ width: '18%' }}>كود</th>
                <th>الصنف</th>
                <th style={{ width: '16%' }}>الكمية (البيع)</th>
                <th style={{ width: '14%' }}>الكمية (الأساس)</th>
                <th style={{ width: '18%' }}>سعر (وحدة أساس)</th>
                <th style={{ width: '18%' }}>الإجمالي</th>
              </tr>
            </thead>
            <tbody>
              {data.items.map((it, idx) => (
                <tr key={`${it.itemId}-${idx}`}>
                  <td className="mono" dir="ltr">{String(it.itemId || '').replace(/-/g, '').slice(-6).toUpperCase()}</td>
                  <td>{it.itemName || '—'}</td>
                  <td className="mono" dir="ltr">
                    {it.salesUnitQty != null && Number.isFinite(Number(it.salesUnitQty))
                      ? `${String(Number(it.salesUnitQty || 0))} ${String(it.uomCode || '').trim() || ''}`.trim()
                      : '—'}
                  </td>
                  <td className="mono" dir="ltr">{String(Number(it.quantityBase || 0))}</td>
                  <td className="mono" dir="ltr">{fmtAmount(Number(it.unitPrice || 0))} {cur}</td>
                  <td className="mono" dir="ltr">{fmtAmount(Number(it.total || 0))} {cur}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={{ marginTop: 16, display: 'flex', justifyContent: 'flex-end' }}>
          <div style={{ width: 320, border: '1px solid #e5e7eb', borderRadius: 8, padding: 10 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 12 }}>
              <div>قيمة المرتجع (بدون ضريبة)</div>
              <div className="mono" dir="ltr">{fmtAmount(Number(data.returnSubtotal || 0))} {cur}</div>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 12, marginTop: 6 }}>
              <div>ضريبة مسترجعة</div>
              <div className="mono" dir="ltr">{fmtAmount(Number(data.taxRefund || 0))} {cur}</div>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 13, marginTop: 10, fontWeight: 800 }}>
              <div>الإجمالي المسترد</div>
              <div className="mono" dir="ltr">{fmtAmount(Number(data.totalRefund || 0))} {cur}</div>
            </div>
          </div>
        </div>

        <div style={{ marginTop: 18, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <div style={{ border: '1px dashed #9ca3af', borderRadius: 8, padding: 12, height: 80 }}>
            <div style={{ fontSize: 12, fontWeight: 700 }}>توقيع العميل</div>
          </div>
          <div style={{ border: '1px dashed #9ca3af', borderRadius: 8, padding: 12, height: 80 }}>
            <div style={{ fontSize: 12, fontWeight: 700 }}>توقيع المسؤول</div>
          </div>
        </div>

        <div style={{ marginTop: 10, fontSize: 11, color: '#6b7280' }}>
          هذا المستند صادر إلكترونياً ولا يحتاج ختم.
        </div>
      </div>
    </div>
  );
};

export default PrintableSalesReturnNote;
