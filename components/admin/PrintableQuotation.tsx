import React from 'react';
import { AZTA_IDENTITY } from '../../config/identity';
import { localizeUomCodeAr } from '../../utils/displayLabels';

export interface QuotationPrintData {
    quotationNumber: string;
    createdAt: string;
    validUntil: string;
    customerName: string;
    customerPhone?: string;
    customerCompany?: string;
    customerAddress?: string;
    currency: string;
    items: Array<{
        itemName: string;
        unit: string;
        quantity: number;
        unitPrice: number;
        total: number;
        notes?: string;
    }>;
    subtotal: number;
    discountType: string;
    discountValue: number;
    discountAmount: number;
    taxRate: number;
    taxAmount: number;
    total: number;
    notes?: string;
    terms?: string;
}

interface PrintableQuotationProps {
    data: QuotationPrintData;
    language?: 'ar' | 'en';
    companyName?: string;
    companyPhone?: string;
    companyAddress?: string;
    logoUrl?: string;
    vatNumber?: string;
    printNumber?: number | null;
}

const PrintableQuotation: React.FC<PrintableQuotationProps> = ({
    data,
    language = 'ar',
    companyName,
    companyPhone,
    companyAddress,
    logoUrl,
    vatNumber,
    printNumber,
}) => {
    const isArabic = language === 'ar';
    const systemName = isArabic ? AZTA_IDENTITY.tradeNameAr : AZTA_IDENTITY.tradeNameEn;
    const resolvedCompanyName = companyName || '';
    const resolvedCompanyPhone = companyPhone || '';
    const resolvedCompanyAddress = companyAddress || '';
    const resolvedLogoUrl = logoUrl || '';
    const resolvedVatNumber = vatNumber || '';
    const branchName = resolvedCompanyName.trim();
    const showBranchName = Boolean(branchName) && branchName !== systemName.trim();
    const currencyLabel = data.currency || '—';

    const fmt = (n: number) => {
        const v = Number(n || 0);
        try {
            return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        } catch {
            return v.toFixed(2);
        }
    };

    const formatDate = (dateStr: string) => {
        try {
            return new Date(dateStr).toLocaleDateString('en-GB');
        } catch {
            return dateStr;
        }
    };

    return (
        <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-visible" dir={isArabic ? 'rtl' : 'ltr'}>
            <style>{`
        @media print {
            @page { size: auto; margin: 6mm; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }
            .qt-doc { max-height: none !important; overflow: visible !important; min-height: auto !important; padding: 0 !important; display: block !important; background: white !important; }
            .qt-table-wrap { overflow: visible !important; }
            .qt-doc::before, .qt-doc::after, .qt-watermark { display: none !important; }
            .qt-footer { margin-top: 8px !important; }
        }
        .qt-doc {
            width: 100%; padding: 3mm 3mm 2mm 3mm;
            display: flex; flex-direction: column;
            font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif;
            color: #0F172A; line-height: 1.2;
            position: relative;
            max-height: none; overflow: visible;
            background-color: #FAFAFA;
        }
        .qt-doc::before {
            content: ''; position: absolute;
            top: 1mm; bottom: 1mm; left: 1mm; right: 1mm;
            border: 1.5pt solid #1E3A8A;
            pointer-events: none; z-index: 50;
        }
        .qt-doc::after {
            content: ''; position: absolute;
            top: 2mm; bottom: 2mm; left: 2mm; right: 2mm;
            border: 0.5pt solid #D4AF37;
            pointer-events: none; z-index: 50;
        }
        .qt-watermark {
            position: absolute; top: 50%; left: 50%;
            transform: translate(-50%, -50%) rotate(-30deg);
            font-size: 10rem; font-weight: 900;
            color: #D4AF37; opacity: 0.03;
            white-space: nowrap; pointer-events: none;
            z-index: 1; letter-spacing: -2px;
        }
        .qt-header {
            display: flex; justify-content: space-between;
            align-items: center; border-bottom: 1.5pt solid #1E3A8A;
            padding-bottom: 2px; margin-bottom: 3px;
        }
        .qt-brand { font-size: 16px; font-weight: 900; letter-spacing: -0.5px; line-height: 1; color: #0F172A; margin-bottom: 1px; }
        .qt-title { font-size: 20px; font-weight: 800; letter-spacing: -1px; color: #D4AF37; line-height: 0.9; }
        .qt-title-sub { font-size: 7px; font-weight: 800; letter-spacing: 1.5px; color: #0F172A; text-transform: uppercase; border-top: 0.5pt solid #D4AF37; padding-top: 1px; margin-top: 1px; text-align: center; }
        .qt-thin-label { font-weight: 300; font-size: 7px; color: #6B7280; text-transform: uppercase; letter-spacing: 0.3px; }
        .qt-bold-value { font-weight: 700; font-size: 9px; color: #0F172A; }
        .qt-tabular { font-variant-numeric: tabular-nums; font-family: 'Arial', sans-serif; letter-spacing: 0.5px; }
        .qt-gold { color: #D4AF37; }
        .qt-info-grid {
            display: flex; justify-content: space-between;
            margin-bottom: 3px; background: #F3F4F6;
            border: 0.5pt solid #E5E7EB; padding: 2px 5px;
        }
        .qt-info-group { display: flex; flex-direction: column; gap: 1px; }
        .qt-info-item { display: flex; flex-direction: column; }
        .qt-table { width: 100%; border-collapse: collapse; margin-bottom: 3px; }
        .qt-table th {
            background-color: #0F172A; color: #FFFFFF;
            padding: 2px 3px; font-weight: 600; font-size: 8px;
            text-transform: uppercase; letter-spacing: 0.3px; border: none;
        }
        .qt-table td {
            padding: 1.5px 3px; font-size: 9px; font-weight: 600;
            border-bottom: 0.5pt solid #E5E7EB; color: #0F172A;
        }
        .qt-table tr:nth-child(even) td { background-color: #F9FAFB; }
        .qt-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A; }
        .qt-totals-section { display: flex; justify-content: flex-end; margin-bottom: 4px; }
        .qt-totals-box { width: 200px; background: #F3F4F6; border: 0.5pt solid #E5E7EB; border-top: 1.5pt solid #1E3A8A; padding: 3px; }
        .qt-totals-row { display: flex; justify-content: space-between; margin-bottom: 2px; font-size: 8px; color: #4B5563; }
        .qt-totals-row.grand { margin-top: 2px; padding-top: 2px; border-top: 0.5pt solid #D1D5DB; font-size: 10px; font-weight: 900; color: #1E3A8A; }
        .qt-conditions { border: 0.5pt dashed #9CA3AF; background: #FFFFFF; padding: 3px; margin-top: 4px; font-size: 7px; color: #4B5563; }
        .qt-conditions-title { font-weight: 800; color: #0F172A; margin-bottom: 2px; }
        .qt-footer { margin-top: 8px; text-align: center; font-size: 7px; color: #4B5563; padding-top: 2px; display: flex; flex-direction: column; align-items: center; gap: 1px; }
        .qt-footer-line { width: 40px; height: 0.5pt; background-color: #D4AF37; margin: 1px 0; }
        .qt-copy-badge {
            position: absolute; top: 3mm; ${isArabic ? 'left' : 'right'}: 3mm;
            background: #0F172A; color: #D4AF37; font-size: 7px; font-weight: 800;
            padding: 1px 5px; border-radius: 2px; z-index: 60; letter-spacing: 0.5px;
        }
      `}</style>

            <div className="qt-doc" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }}>

                <div className="qt-watermark">{AZTA_IDENTITY.tradeNameAr}</div>

                {printNumber != null && printNumber > 0 && (
                    <div className="qt-copy-badge">
                        {isArabic ? `نسخة #${printNumber}` : `COPY #${printNumber}`}
                    </div>
                )}

                {/* ▬▬▬ HEADER ▬▬▬ */}
                <div className="qt-header" style={{ position: 'relative', zIndex: 10 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                        {resolvedLogoUrl && (
                            <div style={{ background: 'white', padding: '2px', border: '0.5pt solid #E5E7EB' }}>
                                <img src={resolvedLogoUrl} alt="Logo" style={{ height: '40px', width: 'auto', objectFit: 'contain' }} />
                            </div>
                        )}
                        <div style={{ display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
                            <div className="qt-brand">{systemName}</div>
                            {showBranchName && (
                                <span style={{ fontSize: '8px', fontWeight: 400, color: '#64748B', marginTop: '1px' }}>({branchName})</span>
                            )}
                            <div style={{ marginTop: '2px', display: 'flex', gap: '6px', fontSize: '6px', color: '#64748B', fontWeight: 700 }}>
                                {resolvedCompanyAddress && <span dir="ltr">Add: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{resolvedCompanyAddress}</span></span>}
                                {resolvedCompanyPhone && <span dir="ltr">TEL: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{resolvedCompanyPhone}</span></span>}
                                {resolvedVatNumber && <span dir="ltr">VAT: <span style={{ fontFamily: 'monospace', color: '#0F172A' }}>{resolvedVatNumber}</span></span>}
                            </div>
                        </div>
                    </div>
                    <div style={{ textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0, zIndex: 10 }}>
                        <div className="qt-title">{isArabic ? 'عرض سعر' : 'QUOTATION'}</div>
                        <div className="qt-title-sub">PRICE QUOTATION</div>
                    </div>
                </div>

                {/* ▬▬▬ INFO GRID ▬▬▬ */}
                <div className="qt-info-grid" style={{ position: 'relative', zIndex: 10 }}>
                    <div className="qt-info-group">
                        <div className="qt-info-item" style={{ marginBottom: '2px' }}>
                            <span className="qt-thin-label">{isArabic ? 'العميل | Customer' : 'Customer'}</span>
                            <span className="qt-bold-value qt-gold">{data.customerName || '—'}</span>
                        </div>
                        {data.customerPhone && (
                            <div className="qt-info-item">
                                <span className="qt-thin-label">{isArabic ? 'الهاتف | Phone' : 'Phone'}</span>
                                <span className="qt-bold-value qt-tabular" dir="ltr">{data.customerPhone}</span>
                            </div>
                        )}
                        {data.customerCompany && (
                            <div className="qt-info-item" style={{ marginTop: '2px' }}>
                                <span className="qt-thin-label">{isArabic ? 'الشركة | Company' : 'Company'}</span>
                                <span className="qt-bold-value">{data.customerCompany}</span>
                            </div>
                        )}
                    </div>

                    <div className="qt-info-group" style={{ borderRight: '0.5pt solid #E5E7EB', borderLeft: '0.5pt solid #E5E7EB', padding: '0 8px' }}>
                        <div className="qt-info-item" style={{ marginBottom: '2px' }}>
                            <span className="qt-thin-label">{isArabic ? 'رقم العرض | Quotation No.' : 'Quotation No.'}</span>
                            <span className="qt-bold-value qt-tabular" dir="ltr" style={{ fontFamily: 'monospace' }}>#{data.quotationNumber}</span>
                        </div>
                        <div className="qt-info-item">
                            <span className="qt-thin-label">{isArabic ? 'التاريخ | Date' : 'Date'}</span>
                            <span className="qt-bold-value qt-tabular" dir="ltr">{formatDate(data.createdAt)}</span>
                        </div>
                    </div>

                    <div className="qt-info-group">
                        <div className="qt-info-item" style={{ marginBottom: '2px' }}>
                            <span className="qt-thin-label">{isArabic ? 'صلاحية العرض | Validity' : 'Valid Until'}</span>
                            <span className="qt-bold-value qt-tabular" dir="ltr">{formatDate(data.validUntil)}</span>
                        </div>
                        <div className="qt-info-item">
                            <span className="qt-thin-label">{isArabic ? 'العملة | Currency' : 'Currency'}</span>
                            <span className="qt-bold-value qt-tabular" dir="ltr">{currencyLabel}</span>
                        </div>
                    </div>
                </div>

                {/* ▬▬▬ TABLE ▬▬▬ */}
                <div className="qt-table-wrap" style={{ position: 'relative', zIndex: 10, width: '100%', overflow: 'visible', minHeight: '80px' }}>
                    <table className={`qt-table ${isArabic ? 'text-right' : 'text-left'}`}>
                        <thead>
                            <tr>
                                <th style={{ width: '5%', textAlign: 'center' }}>م</th>
                                <th className={isArabic ? 'text-right' : 'text-left'} style={{ width: '35%' }}>{isArabic ? 'الصنف | Item' : 'Item Description'}</th>
                                <th style={{ width: '12%', textAlign: 'center' }}>{isArabic ? 'الوحدة' : 'Unit'}</th>
                                <th style={{ width: '12%', textAlign: 'center' }}>{isArabic ? 'الكمية' : 'QTY'}</th>
                                <th style={{ width: '18%', textAlign: 'center' }}>{isArabic ? 'السعر' : 'Price'}</th>
                                <th style={{ width: '18%', textAlign: 'center' }}>{isArabic ? 'المجموع' : 'Total'}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {data.items.length === 0 ? (
                                <tr><td colSpan={6} style={{ padding: '12px', textAlign: 'center', color: '#94A3B8' }}>{isArabic ? 'لا توجد أصناف' : 'No items'}</td></tr>
                            ) : (
                                data.items.map((item, idx) => (
                                    <tr key={idx} style={{ pageBreakInside: 'avoid' }}>
                                        <td style={{ textAlign: 'center' }} className="qt-thin-label">{idx + 1}</td>
                                        <td>
                                            <div className="qt-bold-value" style={{ color: '#0F172A' }}>{item.itemName}</div>
                                            {item.notes && <div style={{ fontSize: '7px', color: '#6B7280' }}>{item.notes}</div>}
                                        </td>
                                        <td style={{ textAlign: 'center', fontSize: '8px' }}>{localizeUomCodeAr(String(item.unit || ''))}</td>
                                        <td className="qt-tabular" style={{ textAlign: 'center' }} dir="ltr">{item.quantity}</td>
                                        <td className="qt-tabular" style={{ textAlign: 'center' }} dir="ltr">{fmt(item.unitPrice)}</td>
                                        <td className="qt-tabular qt-bold-value" style={{ textAlign: 'center' }} dir="ltr">{fmt(item.total)}</td>
                                    </tr>
                                ))
                            )}
                        </tbody>
                    </table>
                </div>

                {/* ▬▬▬ TOTALS ▬▬▬ */}
                <div className="qt-totals-section" style={{ position: 'relative', zIndex: 10 }}>
                    <div className="qt-totals-box">
                        <div className="qt-totals-row">
                            <span>{isArabic ? 'المجموع الفرعي | Sub Total' : 'Sub Total'}</span>
                            <span className="qt-tabular" style={{ fontFamily: 'monospace', color: '#0F172A' }} dir="ltr">
                                {fmt(data.subtotal)} {currencyLabel}
                            </span>
                        </div>
                        {data.discountAmount > 0 && (
                            <div className="qt-totals-row" style={{ marginTop: '1px' }}>
                                <span>{isArabic ? 'الخصم | Discount' : 'Discount'}{data.discountType === 'percentage' ? ` (${data.discountValue}%)` : ''}</span>
                                <span className="qt-tabular" style={{ fontFamily: 'monospace', color: '#DC2626' }} dir="ltr">
                                    -{fmt(data.discountAmount)} {currencyLabel}
                                </span>
                            </div>
                        )}
                        {data.taxAmount > 0 && (
                            <div className="qt-totals-row" style={{ marginTop: '1px' }}>
                                <span>{isArabic ? `الضريبة (${data.taxRate}%) | Tax` : `Tax (${data.taxRate}%)`}</span>
                                <span className="qt-tabular" style={{ fontFamily: 'monospace', color: '#0F172A' }} dir="ltr">
                                    {fmt(data.taxAmount)} {currencyLabel}
                                </span>
                            </div>
                        )}
                        <div className="qt-totals-row grand" style={{ marginTop: '2px', borderTop: '0.5pt solid #D1D5DB', paddingTop: '2px' }}>
                            <span>{isArabic ? 'الإجمالي | Grand Total' : 'Grand Total'}</span>
                            <span className="qt-tabular qt-gold" style={{ fontFamily: 'monospace' }} dir="ltr">
                                {fmt(data.total)} {currencyLabel}
                            </span>
                        </div>
                    </div>
                </div>

                {/* ▬▬▬ TERMS & NOTES ▬▬▬ */}
                <div className="qt-conditions" style={{ position: 'relative', zIndex: 10 }}>
                    <div className="qt-conditions-title">{isArabic ? 'الشروط والأحكام | Terms & Conditions' : 'Terms & Conditions'}</div>
                    {data.terms ? (
                        <div style={{ whiteSpace: 'pre-wrap' }}>{data.terms}</div>
                    ) : (
                        <div style={{ display: 'flex', flexDirection: 'column', gap: '1px' }}>
                            <p>- عرض السعر صالح حتى {formatDate(data.validUntil)} ويخضع لتوافر الكميات في المخزون.</p>
                            <p>- الأسعار المعروضة قابلة للتغيير بعد انتهاء فترة الصلاحية أو عند تغير أسعار الصرف بشكل ملحوظ.</p>
                            <p>- هذا المستند لا يُعد فاتورة ضريبية رسمية، ولا يمكن استخدامه كإثبات للدفع.</p>
                        </div>
                    )}
                    {data.notes && (
                        <div style={{ marginTop: '3px', borderTop: '0.5pt dashed #D1D5DB', paddingTop: '2px' }}>
                            <span style={{ fontWeight: 800, color: '#0F172A' }}>{isArabic ? 'ملاحظات:' : 'Notes:'}</span> {data.notes}
                        </div>
                    )}
                </div>

                {/* ▬▬▬ FOOTER ▬▬▬ */}
                <div className="qt-footer" style={{ position: 'relative', zIndex: 10, marginTop: 'auto', paddingTop: '4px' }}>
                    <div className="qt-footer-line"></div>
                    <div className="qt-bold-value qt-gold" style={{ marginBottom: '1px', marginTop: '1px', fontFamily: 'sans-serif', letterSpacing: '0.5px' }}>
                        نموذج نظام مرخص — LICENSED SYSTEM FORM
                    </div>
                    <div style={{ fontFamily: 'sans-serif', color: '#94A3B8' }}>{AZTA_IDENTITY.tradeNameAr}</div>
                    <div className="qt-tabular" dir="ltr" style={{ fontSize: '6px', color: '#94A3B8' }}>{new Date().toLocaleString('en-GB')}</div>
                </div>
            </div>
        </div>
    );
};

export default PrintableQuotation;
