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
  quantity: number;
};

export type PrintablePurchaseReturnNoteData = {
  returnId: string;
  purchaseOrderId: string;
  supplierName?: string | null;
  referenceNumber?: string | null;
  returnDate: string;
  reason?: string | null;
  currency: string;
  fxRate: number;
  baseCurrency: string;
  totalReturnForeign: number;
  totalReturnBase: number;
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

const PrintablePurchaseReturnNote: React.FC<{ data: PrintablePurchaseReturnNoteData; brand?: Brand }> = ({ data, brand }) => {
  const cur = String(data.currency || '').trim().toUpperCase() || data.baseCurrency || 'YER';
  const baseCur = String(data.baseCurrency || '').trim().toUpperCase() || 'YER';
  const title = 'إشعار مرتجع مشتريات (Supplier Return Note)';
  const idShort = String(data.returnId || '').replace(/-/g, '').slice(-8).toUpperCase();
  const hasForeign = cur && baseCur && cur !== baseCur && Number(data.fxRate || 0) > 0;

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
            <div style={{ fontSize: 12, color: '#374151' }}>
              أمر الشراء: <span className="mono">{String(data.purchaseOrderId || '').slice(-8)}</span>
            </div>
          </div>
        </div>

        <div style={{ marginTop: 16, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <div style={{ border: '1px solid #e5e7eb', borderRadius: 8, padding: 10 }}>
            <div style={{ fontWeight: 800, marginBottom: 6 }}>بيانات المورد</div>
            <div style={{ fontSize: 12 }}>الاسم: {data.supplierName || '—'}</div>
            <div style={{ fontSize: 12 }}>مرجع المورد: <span className="mono" dir="ltr">{data.referenceNumber || '—'}</span></div>
          </div>
          <div style={{ border: '1px solid #e5e7eb', borderRadius: 8, padding: 10 }}>
            <div style={{ fontWeight: 800, marginBottom: 6 }}>بيانات المرتجع</div>
            <div style={{ fontSize: 12 }}>السبب: {data.reason || '—'}</div>
            {hasForeign ? <div style={{ fontSize: 12 }}>سعر الصرف: <span className="mono" dir="ltr">{fmtAmount(Number(data.fxRate || 0))}</span></div> : null}
          </div>
        </div>

        <div style={{ marginTop: 16 }}>
          <table>
            <thead>
              <tr>
                <th style={{ width: '18%' }}>كود</th>
                <th>الصنف</th>
                <th style={{ width: '12%' }}>الكمية</th>
              </tr>
            </thead>
            <tbody>
              {data.items.map((it, idx) => (
                <tr key={`${it.itemId}-${idx}`}>
                  <td className="mono" dir="ltr">{String(it.itemId || '').replace(/-/g, '').slice(-6).toUpperCase()}</td>
                  <td>{it.itemName || '—'}</td>
                  <td className="mono" dir="ltr">{String(Number(it.quantity || 0))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={{ marginTop: 16, display: 'flex', justifyContent: 'flex-end' }}>
          <div style={{ width: 360, border: '1px solid #e5e7eb', borderRadius: 8, padding: 10 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 12 }}>
              <div>إجمالي المرتجع</div>
              <div className="mono" dir="ltr">{fmtAmount(Number(data.totalReturnForeign || 0))} {cur}</div>
            </div>
            {hasForeign ? (
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 12, marginTop: 6 }}>
                <div>بالعملة الأساسية</div>
                <div className="mono" dir="ltr">{fmtAmount(Number(data.totalReturnBase || 0))} {baseCur}</div>
              </div>
            ) : null}
          </div>
        </div>

        <div style={{ marginTop: 18, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <div style={{ border: '1px dashed #9ca3af', borderRadius: 8, padding: 12, height: 80 }}>
            <div style={{ fontSize: 12, fontWeight: 700 }}>توقيع المورد</div>
          </div>
          <div style={{ border: '1px dashed #9ca3af', borderRadius: 8, padding: 12, height: 80 }}>
            <div style={{ fontSize: 12, fontWeight: 700 }}>توقيع المستلم</div>
          </div>
        </div>

        <div style={{ marginTop: 10, fontSize: 11, color: '#6b7280' }}>
          هذا المستند صادر إلكترونياً ولا يحتاج ختم.
        </div>
      </div>
    </div>
  );
};

export default PrintablePurchaseReturnNote;

