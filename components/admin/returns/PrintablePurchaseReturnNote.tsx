import React from 'react';
import DocumentAuditFooter from '../documents/DocumentAuditFooter';
import { DocumentAuditInfo } from '../../../utils/documentStandards';
import PrintCopyBadge from '../documents/PrintCopyBadge';
import { AZTA_IDENTITY } from '../../../config/identity';
import { localizeUomCodeAr } from '../../../utils/displayLabels';

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
  unitCost?: number;
  totalCost?: number;
  uomCode?: string;
};

export type PrintablePurchaseReturnNoteData = {
  returnId: string;
  purchaseOrderId: string;
  poNumber?: string | null;
  supplierName?: string | null;
  referenceNumber?: string | null;
  warehouseName?: string | null;
  returnDate: string;
  reason?: string | null;
  currency: string;
  fxRate: number;
  baseCurrency: string;
  totalReturnForeign: number;
  totalReturnBase: number;
  items: ReturnItem[];
};

const fmtAmount = (n: number, cur?: string) => {
  const v = Number(n || 0);
  const c = String(cur || '').trim().toUpperCase();
  const dp = c === 'YER' ? 0 : 2;
  try {
    return v.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
  } catch {
    return v.toFixed(dp);
  }
};

const fmtDate = (iso: string) => {
  try {
    const d = new Date(iso);
    return `${d.toLocaleDateString('en-GB')} ${d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false })}`;
  } catch {
    return iso;
  }
};

const PrintablePurchaseReturnNote: React.FC<{ data: PrintablePurchaseReturnNoteData; brand?: Brand; audit?: DocumentAuditInfo | null; printNumber?: number | null }> = ({ data, brand, audit, printNumber }) => {
  const cur = String(data.currency || '').trim().toUpperCase() || data.baseCurrency || 'YER';
  const baseCur = String(data.baseCurrency || '').trim().toUpperCase() || 'YER';
  const hasForeign = cur && baseCur && cur !== baseCur && Number(data.fxRate || 0) > 0;
  const systemName = brand?.name || AZTA_IDENTITY.tradeNameAr;

  const uomLabel = (code?: string) => {
    const raw = String(code || '').trim();
    if (!raw) return '—';
    if (/[\u0600-\u06FF]/.test(raw)) return raw;
    const mapped = localizeUomCodeAr(raw);
    if (mapped && mapped !== '—' && mapped !== raw) return mapped;
    const lower = raw.toLowerCase();
    if (lower === 'piece' || lower === 'pcs' || lower === 'pc') return 'حبة';
    if (lower === 'carton' || lower === 'ctn') return 'كرتون';
    if (lower === 'box') return 'صندوق';
    if (lower === 'pack' || lower === 'pkt') return 'عبوة';
    if (lower === 'bottle') return 'زجاجة';
    if (lower === 'kg') return 'كجم';
    if (lower === 'gram' || lower === 'g') return 'جرام';
    if (lower === 'bag') return 'كيس';
    if (lower === 'bundle') return 'ربطة';
    return raw;
  };

  // Calculate item totals for items missing total_cost
  const itemsWithTotals = data.items.map(it => ({
    ...it,
    totalCost: Number(it.totalCost || 0) > 0 ? Number(it.totalCost) : (Number(it.quantity || 0) * Number(it.unitCost || 0)),
  }));
  const calcTotal = itemsWithTotals.reduce((s, it) => s + (it.totalCost || 0), 0);
  const displayTotal = Number(data.totalReturnForeign || 0) > 0 ? data.totalReturnForeign : calcTotal;

  return (
    <div className="thermal-invoice" dir="rtl">
      <style>{`
        .thermal-invoice {
            font-family: 'Tahoma', 'Arial', sans-serif;
            font-size: 12px;
            line-height: 1.4;
            color: #000;
            width: 80mm;
            max-width: 80mm;
            margin: 0 auto;
            padding: 0 2px;
            background: white;
        }
        @media print {
            @page {
                margin: 0;
                size: auto;
            }
            body {
                margin: 0;
                padding: 0;
            }
            .thermal-invoice {
                width: 100%;
                max-width: none;
                padding: 5px;
            }
        }
        .text-center { text-align: center; }
        .text-right { text-align: right; }
        .text-left { text-align: left; }
        .font-bold { font-weight: bold; }
        .text-xs { font-size: 11px; }
        .text-sm { font-size: 12px; }
        .text-lg { font-size: 15px; }
        .text-xl { font-size: 18px; }
        .mb-1 { margin-bottom: 4px; }
        .mb-2 { margin-bottom: 8px; }
        .mt-1 { margin-top: 4px; }
        .mt-2 { margin-top: 8px; }
        .py-1 { padding-top: 4px; padding-bottom: 4px; }
        .border-b { border-bottom: 1px dashed #000; }
        .border-t { border-top: 1px dashed #000; }
        .border-y { border-top: 1px dashed #000; border-bottom: 1px dashed #000; }
        .flex { display: flex; justify-content: space-between; align-items: baseline; }
        .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; letter-spacing: -0.5px; }
        .logo-img { height: 80px; margin-bottom: 5px; display: block; margin-left: auto; margin-right: auto; }
        table { width: 100%; border-collapse: collapse; }
        th { text-align: right; font-size: 11px; border-bottom: 1px dashed #000; padding-bottom: 4px; }
        td { padding: 3px 0; vertical-align: top; font-size: 11px; }
        .total-box { border: 2px solid #000; padding: 8px; margin-top: 10px; border-radius: 4px; }
        .watermark { 
            position: fixed; top: 30%; left: 50%; transform: translate(-50%, -50%) rotate(-45deg);
            font-size: 40px; font-weight: bold; color: rgba(0,0,0,0.06); pointer-events: none; z-index: 0; border: 3px solid rgba(0,0,0,0.06); padding: 8px 30px;
        }
      `}</style>

      <div className="watermark">{systemName}</div>

      {/* ═══ HEADER ═══ */}
      <div className="text-center mb-2">
        {brand?.logoUrl && <img src={brand.logoUrl} alt="Logo" className="logo-img" />}
        <div className="font-bold text-lg mb-1">{systemName}</div>
        {brand?.address && <div className="text-xs">{brand.address}</div>}
        {brand?.contactNumber && <div className="text-xs" dir="ltr">TEL: {brand.contactNumber}</div>}
      </div>

      <div className="text-center border-y py-1 mb-2">
        <div className="font-bold text-lg">إشعار مرتجع مشتريات</div>
        <div className="text-xs mt-1">Supplier Return Note</div>
        <PrintCopyBadge printNumber={printNumber} position="top-left" />
      </div>

      {/* ═══ INFO ═══ */}
      <div className="mb-2 text-sm">
        <div className="flex">
          <span>رقم الإشعار:</span>
          <span className="font-bold tabular" dir="ltr">{String(data.returnId || '').replace(/-/g, '').slice(-8).toUpperCase()}</span>
        </div>
        <div className="flex">
          <span>التاريخ:</span>
          <span className="tabular" dir="ltr">{fmtDate(data.returnDate)}</span>
        </div>
        <div className="flex">
          <span>المورد:</span>
          <span className="font-bold">{data.supplierName || '—'}</span>
        </div>
        <div className="flex">
          <span>رقم أمر الشراء:</span>
          <span className="tabular font-bold" dir="ltr">{data.poNumber || String(data.purchaseOrderId || '').slice(-8).toUpperCase()}</span>
        </div>
        {data.referenceNumber && (
          <div className="flex">
            <span>مرجع المورد:</span>
            <span className="tabular" dir="ltr">{data.referenceNumber}</span>
          </div>
        )}
        {data.warehouseName && (
          <div className="flex">
            <span>المستودع:</span>
            <span className="font-bold">{data.warehouseName}</span>
          </div>
        )}
        <div className="flex">
          <span>العملة:</span>
          <span className="font-bold" dir="ltr">{cur}{hasForeign ? ` (سعر الصرف: ${fmtAmount(data.fxRate, cur)})` : ''}</span>
        </div>
        {data.reason && (
          <div className="flex">
            <span>السبب:</span>
            <span>{data.reason}</span>
          </div>
        )}
      </div>

      {/* ═══ ITEMS TABLE ═══ */}
      <table className="mb-2">
        <thead>
          <tr>
            <th style={{ width: '6%' }}>م</th>
            <th style={{ width: '30%' }}>الصنف</th>
            <th style={{ width: '14%', textAlign: 'center' }}>الوحدة</th>
            <th style={{ width: '10%', textAlign: 'center' }}>الكمية</th>
            <th style={{ width: '20%', textAlign: 'center' }}>سعر الوحدة</th>
            <th style={{ width: '20%', textAlign: 'left' }}>الإجمالي</th>
          </tr>
        </thead>
        <tbody>
          {itemsWithTotals.map((it, idx) => (
            <tr key={`${it.itemId}-${idx}`}>
              <td className="text-center tabular">{idx + 1}</td>
              <td>
                <div className="font-bold">{it.itemName || '—'}</div>
              </td>
              <td className="text-center">{uomLabel(it.uomCode)}</td>
              <td className="text-center tabular" dir="ltr">{String(Number(it.quantity || 0))}</td>
              <td className="text-center tabular" dir="ltr">{fmtAmount(Number(it.unitCost || 0), cur)} {cur}</td>
              <td className="text-left tabular font-bold" dir="ltr">{fmtAmount(it.totalCost || 0, cur)} {cur}</td>
            </tr>
          ))}
        </tbody>
      </table>

      {/* ═══ TOTALS ═══ */}
      <div className="total-box text-center mb-2">
        <div className="text-sm font-bold mb-1">إجمالي المرتجع | Total Return</div>
        <div className="text-xl font-bold tabular" dir="ltr">
          {fmtAmount(displayTotal, cur)} {cur}
        </div>
        {hasForeign && (
          <>
            <div className="text-xs mt-1" dir="ltr">
              سعر الصرف: {fmtAmount(data.fxRate, cur)}
            </div>
            <div className="text-sm font-bold mt-1 tabular" dir="ltr">
              بالعملة الأساسية: {fmtAmount(data.totalReturnBase, baseCur)} {baseCur}
            </div>
          </>
        )}
      </div>

      {/* ═══ SIGNATURES ═══ */}
      <div className="mb-2" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
        <div style={{ borderTop: '1px solid #000', paddingTop: '4px', textAlign: 'center' }}>
          <div className="text-xs font-bold">توقيع المستلم</div>
          <div className="text-xs">Receiver</div>
        </div>
        <div style={{ borderTop: '1px solid #000', paddingTop: '4px', textAlign: 'center' }}>
          <div className="text-xs font-bold">توقيع مندوب المورد</div>
          <div className="text-xs">Supplier Rep.</div>
        </div>
      </div>

      <div className="text-center text-xs border-t py-1 mb-1" style={{ color: '#666' }}>
        هذا المستند صادر إلكترونياً ولا يحتاج إلى ختم
      </div>

      {/* ═══ FOOTER ═══ */}
      <div className="text-center text-xs mt-2">
        <div className="font-bold">نموذج نظام مرخص — LICENSED SYSTEM FORM</div>
        <DocumentAuditFooter
          audit={{ printedAt: new Date().toISOString(), generatedBy: systemName, ...(audit || {}) }}
          extraRight={<div style={{ color: '#999' }}>{systemName}</div>}
        />
      </div>
    </div>
  );
};

export default PrintablePurchaseReturnNote;
