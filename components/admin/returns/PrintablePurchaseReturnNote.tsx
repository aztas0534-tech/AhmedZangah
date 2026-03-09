import React from 'react';
import DocumentAuditFooter from '../documents/DocumentAuditFooter';
import { DocumentAuditInfo } from '../../../utils/documentStandards';
import PrintCopyBadge from '../documents/PrintCopyBadge';

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

const PrintablePurchaseReturnNote: React.FC<{ data: PrintablePurchaseReturnNoteData; brand?: Brand; audit?: DocumentAuditInfo | null; printNumber?: number | null }> = ({ data, brand, audit, printNumber }) => {
  const cur = String(data.currency || '').trim().toUpperCase() || data.baseCurrency || 'YER';
  const baseCur = String(data.baseCurrency || '').trim().toUpperCase() || 'YER';
  const title = 'إشعار مرتجع مشتريات (Supplier Return Note)';
  const idShort = String(data.returnId || '').replace(/-/g, '').slice(-8).toUpperCase();
  const hasForeign = cur && baseCur && cur !== baseCur && Number(data.fxRate || 0) > 0;

  return (
    <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir="rtl">
      <style>{`
        @media print {
            @page { size: A5 portrait; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }

            .document-container { 
                width: 100% !important; 
                padding: 3mm 3mm 2mm 3mm !important;
                display: flex !important; flex-direction: column !important;
                font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                color: #0F172A !important; line-height: 1.2 !important;
                position: relative !important;
                max-height: 210mm !important; overflow: hidden !important;
                background-color: #FAFAFA !important;
            }

            .luxury-watermark {
                position: absolute !important; top: 50% !important; left: 50% !important;
                transform: translate(-50%, -50%) rotate(-30deg) !important;
                font-size: 10rem !important; font-weight: 900 !important;
                color: #D4AF37 !important; opacity: 0.03 !important;
                white-space: nowrap !important; pointer-events: none !important;
                z-index: 1 !important; letter-spacing: -2px !important;
            }

            .document-container::before {
                content: ''; position: absolute !important;
                top: 1mm; bottom: 1mm; left: 1mm; right: 1mm;
                border: 1.5pt solid #1E3A8A !important;
                pointer-events: none !important; z-index: 50 !important;
            }
            .document-container::after {
                content: ''; position: absolute !important;
                top: 2mm; bottom: 2mm; left: 2mm; right: 2mm;
                border: 0.5pt solid #D4AF37 !important;
                pointer-events: none !important; z-index: 50 !important;
            }

            .text-gold { color: #D4AF37 !important; }
            .text-charcoal { color: #0F172A !important; }
            .bg-gold-50 { background-color: #fcf9f2 !important; }
            .font-thin-label { font-weight: 300 !important; font-size: 7px !important; color: #6B7280 !important; text-transform: uppercase !important; letter-spacing: 0.3px !important; }
            .font-bold-value { font-weight: 700 !important; font-size: 9px !important; color: #0F172A !important; }
            .tabular { font-variant-numeric: tabular-nums; font-family: 'Arial', sans-serif; letter-spacing: 0.5px; }

            .luxury-header {
                display: flex !important; justify-content: space-between !important;
                align-items: center !important; border-bottom: 1.5pt solid #1E3A8A !important;
                padding-bottom: 2px !important; margin-bottom: 3px !important;
            }
            .brand-name { font-size: 16px !important; font-weight: 900 !important; letter-spacing: -0.5px !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 1px !important; }
            .doc-title { font-size: 18px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #D4AF37 !important; line-height: 0.9 !important; }
            .title-sub { font-size: 7px !important; font-weight: 800 !important; letter-spacing: 1.5px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #D4AF37 !important; padding-top: 1px !important; margin-top: 1px !important; text-align: center !important; }
            
            .info-grid {
                display: flex !important; justify-content: space-between !important;
                margin-bottom: 3px !important; background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important; padding: 2px 5px !important;
            }
            .info-group { display: flex !important; flex-direction: column !important; gap: 1px !important; }
            .info-item { display: flex !important; flex-direction: column !important; }

            .luxury-table { width: 100% !important; border-collapse: collapse !important; margin-bottom: 3px !important; table-layout: fixed !important; }
            .luxury-table th {
                background-color: #0F172A !important; color: #FFFFFF !important;
                padding: 2px 3px !important; font-weight: 600 !important; font-size: 8px !important;
                text-transform: uppercase !important; letter-spacing: 0.3px !important; border: none !important;
            }
            .luxury-table td {
                padding: 1.5px 3px !important; font-size: 9px !important; font-weight: 600 !important;
                border-bottom: 0.5pt solid #E5E7EB !important; color: #0F172A !important;
                word-break: break-word !important; overflow-wrap: anywhere !important;
            }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
            .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }

            .totals-section { display: flex !important; justify-content: flex-end !important; margin-bottom: 4px !important; }
            .totals-box { width: 200px !important; background: #F3F4F6 !important; border: 0.5pt solid #E5E7EB !important; border-top: 1.5pt solid #1E3A8A !important; padding: 3px !important; }
            .totals-row { display: flex !important; justify-content: space-between !important; margin-bottom: 2px !important; font-size: 8px !important; color: #4B5563 !important; }
            .totals-row.grand-total { margin-top: 2px !important; padding-top: 2px !important; border-top: 0.5pt solid #D1D5DB !important; font-size: 10px !important; font-weight: 900 !important; color: #1E3A8A !important; }

            .signatures { display: grid !important; grid-template-columns: 1fr 1fr !important; gap: 6px !important; margin-top: 4px !important; }
            .signature-box { border: 0.5pt dashed #9CA3AF !important; background: #FFFFFF !important; padding: 3px !important; height: 30px !important; position: relative !important; display: flex !important; align-items: flex-end !important; justify-content: center !important; }
            .signature-label { position: absolute !important; top: 2px !important; right: 4px !important; font-size: 7px !important; color: #6B7280 !important; font-weight: 600 !important; }

            .luxury-footer {
                margin-top: auto !important; text-align: center !important;
                font-size: 7px !important; color: #4B5563 !important; padding-top: 2px !important;
                page-break-inside: avoid !important; display: flex !important;
                flex-direction: column !important; align-items: center !important; gap: 1px !important;
            }
            .footer-line { width: 40px !important; height: 0.5pt !important; background-color: #D4AF37 !important; margin: 1px 0 !important; }
        }
      `}</style>

      <div className="document-container w-full mx-auto p-12 bg-[#FAFAFA] flex flex-col text-blue-950 print:p-0" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }}>

        <div className="luxury-watermark">{brand?.name || 'AZTA ERP'}</div>

        {/* ▬▬▬ HEADER ▬▬▬ */}
        <div className="luxury-header relative z-10 flex flex-col md:flex-row justify-between items-center md:items-end gap-6 pb-6 mb-8 border-b-2 border-slate-900 print:pb-0 print:mb-0 print:border-none print:flex-row">
          <div className="flex items-center gap-6 print:gap-4">
            {brand?.logoUrl && (
              <div className="bg-white p-2 print:p-1 print:border print:border-slate-200 z-10">
                <img src={brand.logoUrl} alt="Logo" className="h-24 print:h-16 w-auto object-contain print:grayscale" />
              </div>
            )}
            <div className="flex flex-col justify-center">
              <h1 className="brand-name">
                {brand?.name || 'AZTA ERP'}
                {(brand?.branchName) && (
                  <span className="text-sm font-normal text-slate-500 mr-2 print:text-[8px] font-sans">({brand?.branchName})</span>
                )}
              </h1>
              <div className="mt-2 print:mt-1 flex gap-3 text-sm print:text-[6px] text-slate-600 font-bold">
                {brand?.address && <span dir="ltr">Add: <span className="font-mono text-blue-950">{brand.address}</span></span>}
                {brand?.contactNumber && <span dir="ltr">TEL: <span className="font-mono text-blue-950">{brand.contactNumber}</span></span>}
              </div>
            </div>
          </div>

          <div className="text-center flex flex-col items-center flex-shrink-0 z-10 md:text-left rtl:text-left">
            <h2 className="doc-title">{title}</h2>
            <div className="title-sub">SUPPLIER RETURN NOTE</div>
          </div>
          <PrintCopyBadge printNumber={printNumber} position="top-left" />
        </div>

        {/* ▬▬▬ INFO SECTION ▬▬▬ */}
        <div className="info-grid relative z-10 mb-6 print:mb-3">
          <div className="info-group">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">اسم المورد | Supplier Name</span>
              <span className="font-bold-value text-gold">{data.supplierName || '—'}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">مرجع المورد | Supplier Ref</span>
              <span className="font-bold-value text-charcoal tabular font-mono" dir="ltr">{data.referenceNumber || '—'}</span>
            </div>
          </div>

          <div className="info-group border-r border-slate-300 pr-4 print:border-[#E5E7EB]">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">رقم الإشعار | Note Number</span>
              <span className="font-bold-value font-mono text-charcoal" dir="ltr">{idShort}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">التاريخ | Date</span>
              <span className="font-bold-value font-mono tabular" dir="ltr">{fmtTime(data.returnDate)}</span>
            </div>
          </div>

          <div className="info-group border-r border-slate-300 pr-4 print:border-[#E5E7EB]">
            <div className="info-item mb-2 print:mb-1">
              <span className="font-thin-label">السبب | Reason</span>
              <span className="font-bold-value text-charcoal">{data.reason || '—'}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">أمر الشراء المرتبط | PO Ref</span>
              <span className="font-bold-value font-mono tabular" dir="ltr">{String(data.purchaseOrderId || '').slice(-8)}</span>
            </div>
          </div>
        </div>

        {/* ▬▬▬ TABLE ▬▬▬ */}
        <div className="relative z-10 w-full overflow-hidden mb-4 print:mb-2">
          <table className="luxury-table print:w-full text-right">
            <thead>
              <tr>
                <th style={{ width: '15%' }}>الرمز</th>
                <th style={{ width: '70%' }}>الصنف</th>
                <th style={{ width: '15%' }} className="text-center">الكمية المسترجعة</th>
              </tr>
            </thead>
            <tbody>
              {data.items.length === 0 ? (
                <tr>
                  <td colSpan={3} className="py-4 text-center text-slate-400">لا توجد أصناف</td>
                </tr>
              ) : (
                data.items.map((it, idx) => (
                  <tr key={`${it.itemId}-${idx}`} style={{ pageBreakInside: 'avoid' }}>
                    <td className="tabular font-thin-label text-slate-600" dir="ltr">{String(it.itemId || '').replace(/-/g, '').slice(-6).toUpperCase()}</td>
                    <td>
                      <div className="font-bold-value text-charcoal">{it.itemName || '—'}</div>
                    </td>
                    <td className="text-center tabular font-mono font-bold text-blue-950" dir="ltr">
                      {String(Number(it.quantity || 0))}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* ▬▬▬ TOTALS ▬▬▬ */}
        <div className="totals-section relative z-10">
          <div className="totals-box">
            <div className="totals-row">
              <span>إجمالي المرتجع | Total</span>
              <span className="tabular font-mono" dir="ltr">{fmtAmount(Number(data.totalReturnForeign || 0))} {cur}</span>
            </div>
            {hasForeign && (
              <>
                <div className="totals-row mt-1">
                  <span>سعر الصرف | FX Rate</span>
                  <span className="tabular font-mono text-slate-500" dir="ltr">{fmtAmount(Number(data.fxRate || 0))}</span>
                </div>
                <div className="totals-row grand-total mt-2 border-t border-slate-300 pt-2">
                  <span>بالعملة الأساسية | Base Eq.</span>
                  <span className="tabular font-mono text-gold" dir="ltr">{fmtAmount(Number(data.totalReturnBase || 0))} {baseCur}</span>
                </div>
              </>
            )}
          </div>
        </div>

        {/* ▬▬▬ SIGNATURES ▬▬▬ */}
        <div className="signatures relative z-10 w-full mb-2">
          <div className="signature-box">
            <span className="signature-label">توقيع المستلم | Receiver Sign</span>
          </div>
          <div className="signature-box">
            <span className="signature-label">توقيع المورد (المندوب) | Representative Sign</span>
          </div>
        </div>

        <div className="relative z-10 font-thin-label text-center mt-2 print:mt-1">
          هذا المستند صادر إلكترونياً ولا يحتاج إلى ختم — This document is electronically generated and does not require a stamp
        </div>

        {/* ▬▬▬ FOOTER ▬▬▬ */}
        <div className="luxury-footer relative z-10 w-full font-mono mt-auto pt-6">
          <div className="footer-line"></div>
          <div className="font-bold-value text-gold mb-1 print:mb-0.5 mt-1 font-sans tracking-wide">نموذج نظام مرخص — LICENSED SYSTEM FORM</div>

          <DocumentAuditFooter
            audit={{ printedAt: new Date().toISOString(), generatedBy: brand?.name || 'AZTA ERP', ...(audit || {}) }}
            extraRight={<div className="font-sans text-slate-400">{brand?.name || 'AZTA ERP'}</div>}
          />
        </div>

      </div>
    </div>
  );
};

export default PrintablePurchaseReturnNote;
