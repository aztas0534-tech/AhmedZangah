import { PurchaseOrder } from '../../../types';
import { AZTA_IDENTITY } from '../../../config/identity';
import DocumentAuditFooter from './DocumentAuditFooter';
import { DocumentAuditInfo } from '../../../utils/documentStandards';
import { localizeUomCodeAr } from '../../../utils/displayLabels';
import PrintCopyBadge from './PrintCopyBadge';
import { numberToArabicWords } from '../../../utils/tafqeet';

type Brand = {
  name?: string;
  address?: string;
  contactNumber?: string;
  logoUrl?: string;
  branchName?: string;
  branchCode?: string;
  vatNumber?: string;
};

export default function PrintablePurchaseOrder(props: { order: PurchaseOrder; brand?: Brand; language?: 'ar' | 'en'; documentStatus?: string; referenceId?: string; audit?: DocumentAuditInfo | null; printNumber?: number | null }) {
  const { order, brand, language = 'ar', documentStatus, referenceId, audit, printNumber } = props;
  const docNo = order.poNumber || `PO-${order.id.slice(-6).toUpperCase()}`;
  const currency = String(order.currency || '').toUpperCase() || '—';
  const fx = Number(order.fxRate || 0);
  const items = Array.isArray(order.items) ? order.items : [];
  const systemName = brand?.name || AZTA_IDENTITY.tradeNameAr;
  const systemKey = AZTA_IDENTITY.merchantKey;
  const branchName = (brand?.branchName || '').trim();
  const showBranch = Boolean(branchName) && branchName !== systemName;

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

  const uomLabel = (code: string) => {
    const raw = String(code || '').trim();
    if (!raw) return '—';
    if (/[\u0600-\u06FF]/.test(raw)) return raw;
    const mapped = localizeUomCodeAr(raw);
    if (mapped && mapped !== '—' && mapped !== raw) return mapped;
    const lower = raw.toLowerCase();
    if (lower === 'piece' || lower === 'pcs' || lower === 'pc') return 'حبة';
    if (lower === 'carton' || lower === 'ctn') return 'كرتون';
    if (lower === 'box') return 'صندوق';
    if (lower === 'pack' || lower === 'pkt') return 'باك';
    if (lower === 'bottle') return 'زجاجة';
    if (lower === 'kg') return 'كجم';
    if (lower === 'gram' || lower === 'g') return 'جرام';
    if (lower === 'bag') return 'كيس';
    if (lower === 'bundle') return 'ربطة';
    return raw;
  };

  const fmt = (n: number) => {
    const v = Number(n || 0);
    const c = currency.toUpperCase();
    const dp = c === 'YER' ? 0 : 2;
    try {
      return v.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
    } catch {
      return v.toFixed(dp);
    }
  };

  const curLabel = currencyLabelAr(currency);
  const grandTotal = Number(order.totalAmount || 0);
  const statusLabel = documentStatus === 'posted' || documentStatus === 'Approved' ? 'Approved' : (documentStatus || 'DRAFT');
  const statusColor = statusLabel === 'Approved' ? '#166534' : '#b45309';
  const statusBg = statusLabel === 'Approved' ? '#dcfce7' : '#fef3c7';

  return (
    <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir="rtl">
      <style>{`
        @media print {
            @page { size: A5 portrait; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }

            .po-container { 
                width: 100% !important; 
                padding: 3mm 3mm 2mm 3mm !important;
                display: flex !important; flex-direction: column !important;
                font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                color: #0F172A !important; line-height: 1.2 !important;
                position: relative !important; background-color: #FAFAFA !important;
            }

            .luxury-watermark {
                position: absolute !important; top: 50% !important; left: 50% !important;
                transform: translate(-50%, -50%) rotate(-30deg) !important;
                font-size: 12rem !important; font-weight: 900 !important;
                color: #D4AF37 !important; opacity: 0.03 !important;
                white-space: nowrap !important; pointer-events: none !important; z-index: 1 !important;
            }

            .po-container::before {
                content: ''; position: absolute !important;
                top: 1mm; bottom: 1mm; left: 1mm; right: 1mm;
                border: 1.5pt solid #1E3A8A !important;
                pointer-events: none !important; z-index: 50 !important;
            }
            .po-container::after {
                content: ''; position: absolute !important;
                top: 2mm; bottom: 2mm; left: 2mm; right: 2mm;
                border: 0.5pt solid #D4AF37 !important;
                pointer-events: none !important; z-index: 50 !important;
            }

            .font-thin-label { font-weight: 800 !important; font-size: 10px !important; color: #111827 !important; text-transform: uppercase !important; letter-spacing: 0.3px !important; }
            .font-bold-value { font-weight: 900 !important; font-size: 12px !important; color: #000000 !important; }

            .luxury-header {
                display: flex !important; justify-content: space-between !important;
                align-items: center !important; border-bottom: 1.5pt solid #1E3A8A !important;
                padding-bottom: 2px !important; margin-bottom: 4px !important;
            }
            .brand-name { font-size: 18px !important; font-weight: 900 !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 1px !important; }
            .po-title { font-size: 26px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #1E3A8A !important; line-height: 0.9 !important; }
            .title-sub { font-size: 8px !important; font-weight: 800 !important; letter-spacing: 1.5px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #1E3A8A !important; padding-top: 1px !important; margin-top: 1px !important; text-align: center !important; }

            .info-grid {
                display: flex !important; justify-content: space-between !important;
                margin-bottom: 3px !important; background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important; padding: 2px 5px !important;
            }
            .info-group { display: flex !important; flex-direction: column !important; gap: 1px !important; }
            .info-item { display: flex !important; flex-direction: column !important; }

            .luxury-table { width: 100% !important; border-collapse: collapse !important; margin-bottom: 3px !important; }
            .luxury-table thead { display: table-header-group !important; }
            .luxury-table th {
                background-color: #0F172A !important; color: #FFFFFF !important;
                padding: 1.5px 2px !important; font-weight: 700 !important;
                font-size: 10px !important; text-transform: uppercase !important; border: none !important;
            }
            .luxury-table td {
                padding: 1.5px 2px !important; font-size: 11px !important; font-weight: 700 !important;
                line-height: 1 !important; border-bottom: 0.5pt solid #E5E7EB !important; color: #0F172A !important;
            }
            .luxury-table tr { page-break-inside: avoid !important; }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
            .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }

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
            .signatures-section { page-break-inside: avoid !important; }
        }

        @media screen {
            .po-container { max-width: 700px; margin: 0 auto; padding: 24px; background: #FAFAFA; font-family: 'Tajawal', 'Cairo', sans-serif; }
            .luxury-header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #1E3A8A; padding-bottom: 12px; margin-bottom: 16px; }
            .brand-name { font-size: 18px; font-weight: 900; color: #0F172A; }
            .po-title { font-size: 28px; font-weight: 800; color: #1E3A8A; }
            .title-sub { font-size: 10px; font-weight: 800; color: #0F172A; text-transform: uppercase; border-top: 1px solid #1E3A8A; padding-top: 2px; margin-top: 2px; text-align: center; }
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
            .grand-total-row { display: flex; justify-content: space-between; align-items: center; background-color: #0F172A; color: white; padding: 8px 12px; margin-top: 4px; border-radius: 4px; }
            .grand-total-label { font-size: 14px; font-weight: 800; color: #FFFFFF; }
            .grand-total-value { font-size: 20px; font-weight: 900; color: #D4AF37; font-family: monospace; }
            .luxury-watermark { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%) rotate(-30deg); font-size: 8rem; font-weight: 900; color: #D4AF37; opacity: 0.04; pointer-events: none; z-index: 1; }
            .luxury-footer { margin-top: 16px; text-align: center; font-size: 10px; color: #6B7280; }
            .footer-line { width: 40px; height: 1px; background-color: #D4AF37; margin: 4px auto; }
            .signatures-section { margin-top: 16px; }
        }
      `}</style>

      <div className="po-container" style={{ fontFamily: 'Tajawal, Cairo, sans-serif', position: 'relative' }}>

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
                {brand?.vatNumber && <span dir="ltr">VAT: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{brand.vatNumber}</span></span>}
                {brand?.contactNumber && <span dir="ltr">TEL: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{brand.contactNumber}</span></span>}
              </div>
            </div>
          </div>

          <div style={{ textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0, zIndex: 10 }}>
            <h2 className="po-title">أمر شراء</h2>
            <div className="title-sub">PURCHASE ORDER</div>
            {documentStatus && (
              <div style={{ marginTop: '4px', fontSize: '12px', fontWeight: 800, textAlign: 'center', border: `2px solid ${statusColor}`, color: statusColor, backgroundColor: statusBg, padding: '2px 12px', borderRadius: '4px', letterSpacing: '0.1em' }}>
                {statusLabel}
              </div>
            )}
          </div>
        </div>

        {/* ▬▬▬ INFO SECTION ▬▬▬ */}
        <div className="info-grid" style={{ position: 'relative', zIndex: 10 }}>
          <div className="info-group">
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">المورد | Supplier</span>
              <span className="font-bold-value">{order.supplierName || '—'}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">المستودع | Warehouse</span>
              <span className="font-bold-value">{order.warehouseName || '—'}</span>
            </div>
          </div>

          <div className="info-group" style={{ borderRight: '1px solid #E5E7EB', paddingRight: '12px' }}>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">رقم الأمر | P.O No.</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">#{docNo}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">التاريخ | Date</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{new Date(order.purchaseDate).toLocaleDateString('en-GB')}</span>
            </div>
          </div>

          <div className="info-group" style={{ borderRight: '1px solid #E5E7EB', paddingRight: '12px' }}>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">عملة الشراء | Currency</span>
              <span className="font-bold-value" dir="ltr">{currency} {fx > 0 && <span style={{ fontSize: '9px', color: '#6B7280' }}>(FX: {fx})</span>}</span>
            </div>
            <div className="info-item" style={{ marginBottom: '2px' }}>
              <span className="font-thin-label">المرجع | Reference</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{referenceId || '—'}</span>
            </div>
            <div className="info-item">
              <span className="font-thin-label">فاتورة المورد | Supplier Inv</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }} dir="ltr">{order.referenceNumber || '—'}</span>
            </div>
          </div>
        </div>

        {/* ▬▬▬ TABLE ▬▬▬ */}
        <div style={{ position: 'relative', zIndex: 10, width: '100%' }}>
          <table className="luxury-table" style={{ textAlign: 'right' }}>
            <thead>
              <tr>
                <th style={{ textAlign: 'center', width: '6%' }}>م</th>
                <th style={{ textAlign: 'right', width: '34%' }}>الصنف ITEM</th>
                <th style={{ textAlign: 'center', width: '12%' }}>الوحدة UOM</th>
                <th style={{ textAlign: 'center', width: '12%' }}>الكمية QTY</th>
                <th style={{ textAlign: 'center', width: '18%' }}>سعر الوحدة PRICE</th>
                <th style={{ textAlign: 'center', width: '18%' }}>الإجمالي TOTAL</th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 ? (
                <tr>
                  <td colSpan={6} style={{ textAlign: 'center', padding: '12px', color: '#9CA3AF' }}>لا توجد أصناف</td>
                </tr>
              ) : items.map((it, idx) => {
                const qty = Number(it.quantity || 0);
                const unit = Number(it.unitCost || 0);
                const total = Number(it.totalCost || qty * unit);
                return (
                  <tr key={`${it.id || idx}`} style={{ pageBreakInside: 'avoid' }}>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace', color: '#9CA3AF' }}>{idx + 1}</td>
                    <td style={{ fontWeight: 800, color: '#0F172A' }}>{it.itemName || it.itemId}</td>
                    <td style={{ textAlign: 'center', color: '#475569' }}>{uomLabel((it as any).uomCode || (it as any).uom_code || (it as any).unit || (it as any).uom || '')}</td>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace', fontWeight: 800 }} dir="ltr">{qty}</td>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace' }} dir="ltr">{fmt(unit)}</td>
                    <td style={{ textAlign: 'center', fontFamily: 'monospace', fontWeight: 800 }} dir="ltr">{fmt(total)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {/* ▬▬▬ TOTALS + NOTES ▬▬▬ */}
        <div style={{ position: 'relative', zIndex: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          {/* Notes */}
          <div style={{ flex: 1, paddingLeft: '12px' }}>
            {order.notes && (
              <div style={{ background: '#F8FAFC', border: '1px solid #E5E7EB', padding: '6px', borderRadius: '2px', marginBottom: '8px' }}>
                <div className="font-thin-label" style={{ marginBottom: '2px' }}>ملاحظات | Notes</div>
                <div className="font-bold-value" style={{ fontSize: '11px' }}>{order.notes}</div>
              </div>
            )}
          </div>

          {/* Totals */}
          <div style={{ width: '55%' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '1.5px 3px' }}>
              <span className="font-thin-label">إجمالي الأصناف | Items</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }}>{items.length}</span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '1.5px 3px' }}>
              <span className="font-thin-label">إجمالي الكمية | Total Qty</span>
              <span className="font-bold-value" style={{ fontFamily: 'monospace' }}>{items.reduce((s, it) => s + Number(it.quantity || 0), 0)}</span>
            </div>

            <div className="grand-total-row">
              <span className="grand-total-label">الإجمالي الكلي | TOTAL</span>
              <span className="grand-total-value" style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                {fmt(grandTotal)}
                <span style={{ fontSize: '8px', fontFamily: 'sans-serif', color: 'white', textTransform: 'uppercase', letterSpacing: '0.15em' }}>{curLabel}</span>
              </span>
            </div>
            <div style={{ background: '#F8FAFC', border: '1px solid #E5E7EB', marginTop: '2px', padding: '3px', textAlign: 'center' }}>
              <span className="font-bold-value" style={{ fontSize: '9px' }}>
                {numberToArabicWords(grandTotal, currency, 'هللة / فلس')}
              </span>
            </div>
          </div>
        </div>

        {/* ▬▬▬ SIGNATURES ▬▬▬ */}
        <div className="signatures-section" style={{ position: 'relative', zIndex: 10, marginTop: '12px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-around', alignItems: 'flex-end', paddingLeft: '24px', paddingRight: '24px' }}>
            <div style={{ textAlign: 'center', width: '100px' }}>
              <div style={{ borderTop: '1.5px solid #1E3A8A', paddingTop: '4px' }}>
                <div className="font-thin-label" style={{ fontSize: '9px', fontWeight: 800 }}>إعداد | Prepared By</div>
              </div>
            </div>
            <div style={{ textAlign: 'center', width: '100px' }}>
              <div style={{ borderTop: '1.5px solid #1E3A8A', paddingTop: '4px' }}>
                <div className="font-thin-label" style={{ fontSize: '9px', fontWeight: 800 }}>مراجعة | Checked By</div>
              </div>
            </div>
            <div style={{ textAlign: 'center', width: '100px' }}>
              <div style={{ borderTop: '1.5px solid #1E3A8A', paddingTop: '4px' }}>
                <div className="font-thin-label" style={{ fontSize: '9px', fontWeight: 800 }}>اعتماد | Approved By</div>
              </div>
            </div>
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
}
