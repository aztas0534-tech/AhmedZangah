import React from 'react';
import DocumentAuditFooter from '../documents/DocumentAuditFooter';
import { DocumentAuditInfo } from '../../../utils/documentStandards';
import PrintCopyBadge from '../documents/PrintCopyBadge';
import { AZTA_IDENTITY } from '../../../config/identity';
import { localizeUomCodeAr } from '../../../utils/displayLabels';
import { numberToArabicWords } from '../../../utils/tafqeet';

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

const currencyLabelAr = (codeRaw: string) => {
  const c = String(codeRaw || '').trim().toUpperCase();
  if (!c || c === '—') return 'عملة';
  if (c === 'SAR') return 'ريال سعودي';
  if (c === 'YER') return 'ريال يمني';
  if (c === 'USD') return 'دولار أمريكي';
  if (c === 'EUR') return 'يورو';
  if (c === 'AED') return 'درهم إماراتي';
  return c;
};

const PrintablePurchaseReturnNote: React.FC<{ data: PrintablePurchaseReturnNoteData; brand?: Brand; audit?: DocumentAuditInfo | null; printNumber?: number | null }> = ({ data, brand, audit, printNumber }) => {
  const cur = String(data.currency || '').trim().toUpperCase() || data.baseCurrency || 'YER';
  const baseCur = String(data.baseCurrency || '').trim().toUpperCase() || 'YER';
  const hasForeign = cur && baseCur && cur !== baseCur && Number(data.fxRate || 0) > 0;
  const systemName = brand?.name || AZTA_IDENTITY.tradeNameAr;
  const systemKey = AZTA_IDENTITY.merchantKey;
  const curLabel = currencyLabelAr(cur);
  const branchName = (brand?.branchName || '').trim();
  const showBranch = Boolean(branchName) && branchName !== systemName;

  const uomLabel = (code?: string) => {
    const raw = String(code || '').trim();
    if (!raw) return '—';
    if (/[\u0600-\u06FF]/.test(raw)) return raw;
    const mapped = localizeUomCodeAr(raw);
    if (!mapped || mapped === '—') return 'وحدة';
    return mapped;
  };

  const itemsWithTotals = data.items.map(it => ({
    ...it,
    totalCost: Number(it.totalCost || 0) > 0 ? Number(it.totalCost) : (Number(it.quantity || 0) * Number(it.unitCost || 0)),
  }));
  const calcTotal = itemsWithTotals.reduce((s, it) => s + (it.totalCost || 0), 0);
  const displayTotal = Number(data.totalReturnForeign || 0) > 0 ? data.totalReturnForeign : calcTotal;

  return (
    <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir="rtl">
      <style>{`
        @media print {
            @page { size: A5 portrait; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }

            .return-container { 
                width: 148mm !important; max-width: 148mm !important;
                min-height: 210mm !important;
                padding: 4mm 4mm 3mm 4mm !important;
                display: flex !important;
                flex-direction: column !important;
                font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                color: #0F172A !important;
                line-height: 1.2 !important;
                position: relative !important;
                background-color: #FAFAFA !important;
                overflow: hidden !important; box-sizing: border-box !important;
            }

            /* ══ WATERMARK ══ */
            .luxury-watermark {
                position: absolute !important;
                top: 50% !important; left: 50% !important;
                transform: translate(-50%, -50%) rotate(-30deg) !important;
                font-size: 12rem !important; font-weight: 900 !important;
                color: #D4AF37 !important; opacity: 0.03 !important;
                white-space: nowrap !important; pointer-events: none !important; z-index: 1 !important;
            }

            /* ══ FRAME ══ */
            .return-container::before {
                content: ''; position: absolute !important;
                top: 1mm; bottom: 1mm; left: 1mm; right: 1mm;
                border: 1.5pt solid #1E3A8A !important;
                pointer-events: none !important; z-index: 50 !important;
            }
            .return-container::after {
                content: ''; position: absolute !important;
                top: 2mm; bottom: 2mm; left: 2mm; right: 2mm;
                border: 0.5pt solid #D4AF37 !important;
                pointer-events: none !important; z-index: 50 !important;
            }

            /* ══ Typography ══ */
            .font-thin-label { font-weight: 800 !important; font-size: 7px !important; color: #111827 !important; text-transform: uppercase !important; letter-spacing: 0.2px !important; }
            .font-bold-value { font-weight: 900 !important; font-size: 9px !important; color: #000000 !important; }

            /* ══ HEADER ══ */
            .luxury-header {
                display: flex !important; justify-content: space-between !important;
                align-items: center !important; border-bottom: 1.5pt solid #1E3A8A !important;
                padding-bottom: 2px !important; margin-bottom: 3px !important;
            }
            .brand-name { font-size: 13px !important; font-weight: 900 !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 1px !important; }
            .return-title { font-size: 18px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #b91c1c !important; line-height: 0.9 !important; }
            .title-sub { font-size: 8px !important; font-weight: 800 !important; letter-spacing: 1.5px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #b91c1c !important; padding-top: 1px !important; margin-top: 1px !important; text-align: center !important; }

            /* ══ INFO GRID ══ */
            .info-grid {
                display: flex !important; justify-content: space-between !important;
                margin-bottom: 3px !important; background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important; padding: 2px 5px !important;
            }
            .info-group { display: flex !important; flex-direction: column !important; gap: 1px !important; }
            .info-item { display: flex !important; flex-direction: column !important; }

            /* ══ TABLE ══ */
            .luxury-table { width: 100% !important; border-collapse: collapse !important; margin-bottom: 3px !important; table-layout: fixed !important; }
            .luxury-table thead { display: table-header-group !important; }
            .luxury-table th {
                background-color: #0F172A !important; color: #FFFFFF !important;
                padding: 1px 1px !important; font-weight: 700 !important;
                font-size: 7px !important; text-transform: uppercase !important; border: none !important;
                overflow: hidden !important; word-break: break-all !important;
            }
            .luxury-table td {
                padding: 1px 1px !important; font-size: 8px !important; font-weight: 700 !important;
                line-height: 1.1 !important; border-bottom: 0.5pt solid #E5E7EB !important; color: #0F172A !important;
                overflow: hidden !important; text-overflow: ellipsis !important; white-space: nowrap !important;
            }
            .luxury-table tr { page-break-inside: avoid !important; }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
            .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }

            /* ══ TOTALS ══ */
            .totals-wrapper {
                display: flex !important; justify-content: space-between !important;
                align-items: flex-start !important; page-break-inside: avoid !important;
            }
            .luxury-totals { width: 55% !important; }
            .total-row { display: flex !important; justify-content: space-between !important; padding: 1.5px 3px !important; }
            .grand-total-row {
                display: flex !important; justify-content: space-between !important; align-items: center !important;
                background-color: #0F172A !important; color: white !important;
                padding: 3px 6px !important; margin-top: 2px !important; border-radius: 2px !important;
            }
            .grand-total-label { font-size: 13px !important; font-weight: 800 !important; color: #FFFFFF !important; }
            .grand-total-value { font-size: 18px !important; font-weight: 900 !important; color: #D4AF37 !important; font-family: monospace !important; }

            .luxury-footer {
                margin-top: auto !important; text-align: center !important;
                font-size: 7px !important; color: #4B5563 !important; padding-top: 2px !important;
                page-break-inside: avoid !important;
            }
            .footer-line { width: 40px !important; height: 0.5pt !important; background-color: #D4AF37 !important; margin: 1px auto !important; }

            /* ══ SIGNATURES ══ */
            .signatures-section { page-break-inside: avoid !important; }
        }

        @media screen {
            .return-container { max-width: 700px; margin: 0 auto; padding: 24px; background: #FAFAFA; font-family: 'Tajawal', 'Cairo', sans-serif; }
            .luxury-header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #1E3A8A; padding-bottom: 12px; margin-bottom: 16px; }
            .brand-name { font-size: 18px; font-weight: 900; color: #0F172A; }
            .return-title { font-size: 28px; font-weight: 800; color: #b91c1c; }
            .title-sub { font-size: 10px; font-weight: 800; color: #0F172A; text-transform: uppercase; border-top: 1px solid #b91c1c; padding-top: 2px; margin-top: 2px; text-align: center; }
            .info-grid { display: flex; justify-content: space-between; margin-bottom: 16px; background: #F3F4F6; border: 1px solid #E5E7EB; padding: 8px 12px; border-radius: 4px; }
            .info-group { display: flex; flex-direction: column; gap: 4px; }
            .info-item { display: flex; flex-direction: column; }
            .font-thin-label { font-weight: 700; font-size: 11px; color: #6B7280; text-transform: uppercase; letter-spacing: 0.5px; }
            .font-bold-value { font-weight: 800; font-size: 13px; color: #0F172A; }
            .luxury-table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
            .luxury-table th { background-color: #0F172A; color: #FFFFFF; padding: 6px 8px; font-weight: 700; font-size: 12px; text-transform: uppercase; }
            .luxury-table td { padding: 6px 8px; font-size: 13px; font-weight: 700; border-bottom: 1px solid #E5E7EB; color: #0F172A; }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB; }
            .luxury-table tr:last-child td { border-bottom: 2px solid #1E3A8A; }
            .totals-wrapper { display: flex; justify-content: space-between; align-items: flex-start; }
            .luxury-totals { width: 55%; }
            .total-row { display: flex; justify-content: space-between; padding: 4px 6px; }
            .grand-total-row { display: flex; justify-content: space-between; align-items: center; background-color: #0F172A; color: white; padding: 8px 12px; margin-top: 4px; border-radius: 4px; }
            .grand-total-label { font-size: 14px; font-weight: 800; color: #FFFFFF; }
            .grand-total-value { font-size: 20px; font-weight: 900; color: #D4AF37; font-family: monospace; }
            .luxury-watermark { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%) rotate(-30deg); font-size: 8rem; font-weight: 900; color: #D4AF37; opacity: 0.04; pointer-events: none; z-index: 1; }
            .luxury-footer { margin-top: 16px; text-align: center; font-size: 10px; color: #6B7280; }
            .footer-line { width: 40px; height: 1px; background-color: #D4AF37; margin: 4px auto; }
            .signatures-section { margin-top: 16px; }
        }
      `}</style>

      <div className="return-container" style={{ fontFamily: 'Tajawal, Cairo, sans-serif', position: 'relative' }}>

        <div className="luxury-watermark">{systemName}</div>

        <PrintCopyBadge printNumber={printNumber} position="top-left" />

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
                {brand?.contactNumber && <span dir="ltr">TEL: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{brand.contactNumber}</span></span>}
              </div>
            </div>
          </div>

          <div style={{ textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0, zIndex: 10 }}>
            <h2 className="return-title">مرتجع مشتريات</h2>
            <div className="title-sub">SUPPLIER RETURN NOTE</div>
          </div>
        </div>

        {/* ▬▬▬ INFO SECTION ▬▬▬ */}
        <div className="info-grid" style={{ position: 'relative', zIndex: 10 }}>
          <div className="info-group">
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">المورد | Supplier</span>
              <span className="font-bold-value">{data.supplierName || '—'}</span>
            </div>
            {data.warehouseName && (
              <div className="info-item" style={{ marginBottom: '2px' }}>
                <span className="font-thin-label">المستودع | Warehouse</span>
                <span className="font-bold-value">{data.warehouseName}</span>
              </div>
            )}
            {data.reason && (
              <div className="info-item">
                <span className="font-thin-label">سبب الإرجاع | Reason</span>
                <span className="font-bold-value">{data.reason}</span>
              </div>
            )}
          </div>

          <div className="info-group" style={{ borderRight: '1px solid #E5E7EB', paddingRight: '12px' }}>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">رقم الإشعار | Return No.</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">#{String(data.returnId || '').replace(/-/g, '').slice(-8).toUpperCase()}</span>
            </div>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">التاريخ | Date</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{fmtDate(data.returnDate)}</span>
            </div>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">رقم أمر الشراء | PO No.</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{data.poNumber || String(data.purchaseOrderId || '').slice(-8).toUpperCase()}</span>
            </div>
          </div>

          <div className="info-group" style={{ borderRight: '1px solid #E5E7EB', paddingRight: '12px' }}>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">العملة | Currency</span>
              <span className="font-bold-value">{cur}</span>
            </div>
            {hasForeign && (
              <div className="info-item" style={{ marginBottom: '2px' }}>
                <span className="font-thin-label">سعر الصرف | FX Rate</span>
                <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{fmtAmount(data.fxRate, cur)}</span>
              </div>
            )}
            {data.referenceNumber && (
              <div className="info-item">
                <span className="font-thin-label">مرجع المورد | Ref</span>
                <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{data.referenceNumber}</span>
              </div>
            )}
          </div>
        </div>

        {/* ▬▬▬ TABLE ▬▬▬ */}
        <div style={{ position: 'relative', zIndex: 10, width: '100%' }}>
          <table className="luxury-table" style={{ textAlign: 'right' }}>
            <thead>
              <tr>
                <th style={{ textAlign: 'center', width: '6%' }}>م</th>
                <th style={{ textAlign: 'right', width: '38%' }}>الصنف ITEM</th>
                <th style={{ textAlign: 'center', width: '12%' }}>الوحدة UOM</th>
                <th style={{ textAlign: 'center', width: '10%' }}>الكمية QTY</th>
                <th style={{ textAlign: 'center', width: '17%' }}>سعر الوحدة PRICE</th>
                <th style={{ textAlign: 'center', width: '17%' }}>الإجمالي TOTAL</th>
              </tr>
            </thead>
            <tbody>
              {itemsWithTotals.map((it, idx) => (
                <tr key={`${it.itemId}-${idx}`} style={{ pageBreakInside: 'avoid' }}>
                  <td style={{ textAlign: 'center', fontFamily: 'monospace', color: '#9CA3AF' }}>{idx + 1}</td>
                  <td style={{ fontWeight: 800, color: '#0F172A' }}>{it.itemName || '—'}</td>
                  <td style={{ textAlign: 'center', color: '#475569' }}>{uomLabel(it.uomCode)}</td>
                  <td style={{ textAlign: 'center', fontFamily: 'monospace', fontWeight: 800 }} dir="ltr">{String(Number(it.quantity || 0))}</td>
                  <td style={{ textAlign: 'center', fontFamily: 'monospace' }} dir="ltr">{fmtAmount(Number(it.unitCost || 0), cur)}</td>
                  <td style={{ textAlign: 'center', fontFamily: 'monospace', fontWeight: 800 }} dir="ltr">{fmtAmount(it.totalCost || 0, cur)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* ▬▬▬ TOTALS ▬▬▬ */}
        <div className="totals-wrapper" style={{ position: 'relative', zIndex: 10 }}>
          {/* Stamp / Signatures Area */}
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', paddingTop: '4px' }}>
            <div className="signatures-section" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px', marginTop: '8px' }}>
              <div style={{ borderTop: '1.5px solid #1E3A8A', paddingTop: '6px', textAlign: 'center' }}>
                <div className="font-thin-label" style={{ fontSize: '9px' }}>توقيع المستلم</div>
                <div style={{ fontSize: '7px', color: '#9CA3AF' }}>Receiver</div>
              </div>
              <div style={{ borderTop: '1.5px solid #1E3A8A', paddingTop: '6px', textAlign: 'center' }}>
                <div className="font-thin-label" style={{ fontSize: '9px' }}>توقيع مندوب المورد</div>
                <div style={{ fontSize: '7px', color: '#9CA3AF' }}>Supplier Rep.</div>
              </div>
            </div>
          </div>

          {/* Totals */}
          <div className="luxury-totals">
            <div className="total-row">
              <span className="font-thin-label">إجمالي الأصناف | Items</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }}>
                {itemsWithTotals.length}
              </span>
            </div>
            <div className="total-row">
              <span className="font-thin-label">مجموع الكمية | Total Qty</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }}>
                {itemsWithTotals.reduce((s, it) => s + Number(it.quantity || 0), 0)}
              </span>
            </div>

            <div className="grand-total-row">
              <span className="grand-total-label">إجمالي المرتجع | TOTAL</span>
              <span className="grand-total-value" style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                {fmtAmount(displayTotal, cur)}
                <span style={{ fontSize: '8px', fontFamily: 'sans-serif', color: 'white', textTransform: 'uppercase', letterSpacing: '0.15em' }}>{curLabel}</span>
              </span>
            </div>
            <div style={{ background: '#F8FAFC', border: '1px solid #E5E7EB', marginTop: '2px', padding: '3px', textAlign: 'center' }}>
              <span className="font-bold-value" style={{ fontSize: '9px' }}>
                {numberToArabicWords(Number(displayTotal), cur, 'هللة / فلس')}
              </span>
            </div>

            {hasForeign && (
              <div className="total-row" style={{ marginTop: '3px', background: '#EFF6FF', border: '1px solid #BFDBFE', padding: '3px 6px', borderRadius: '2px' }}>
                <span className="font-thin-label" style={{ color: '#1E40AF' }}>بالعملة الأساسية | Base</span>
                <span className="font-bold-value" style={{ fontFamily: 'monospace', color: '#1E40AF' }}>
                  {fmtAmount(data.totalReturnBase, baseCur)} {baseCur}
                </span>
              </div>
            )}
          </div>
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
};

export default PrintablePurchaseReturnNote;
