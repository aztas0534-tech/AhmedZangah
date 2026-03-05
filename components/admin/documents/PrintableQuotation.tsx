
import { Order } from '../../../types';
import { AZTA_IDENTITY } from '../../../config/identity';
import DocumentAuditFooter from './DocumentAuditFooter';
import { DocumentAuditInfo } from '../../../utils/documentStandards';

type Brand = {
    name?: string;
    address?: string;
    contactNumber?: string;
    logoUrl?: string;
    branchName?: string;
    branchCode?: string;
    vatNumber?: string;
};

export default function PrintableQuotation(props: { order: Order; brand?: Brand; language?: 'ar' | 'en'; audit?: DocumentAuditInfo | null; inStoreLines?: any[]; externalCustomerName?: string; externalCustomerPhone?: string }) {
    const { order, brand, language = 'ar', audit, inStoreLines, externalCustomerName, externalCustomerPhone } = props;
    const docNo = order.id ? `QT-${order.id.slice(-6).toUpperCase()}` : 'NEW';
    const currency = String(order.currency || '').toUpperCase() || '—';

    // order.items are the saved ones. If we haven't saved, we might use inStoreLines
    const rawItems = Array.isArray(order.items) && order.items.length > 0 ? order.items : (Array.isArray(inStoreLines) ? inStoreLines : []);

    const fmt = (n: number) => {
        const v = Number(n || 0);
        try {
            return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        } catch {
            return v.toFixed(2);
        }
    };

    const isArabic = language === 'ar';

    const customerName = externalCustomerName || (order as any).customerName || '—';
    const customerPhone = externalCustomerPhone || (order as any).phoneNumber || '—';

    return (
        <div className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir={isArabic ? 'rtl' : 'ltr'}>
            <style>{`
        @media print {
            @page { size: A5 portrait; margin: 0; }
            body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
            * { box-sizing: border-box; }

            .document-container { 
                width: 100% !important; 
                padding: 2mm 5mm !important;
                display: flex !important;
                flex-direction: column !important;
                font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                color: #0F172A !important;
                line-height: 1.35 !important;
                position: relative !important;
                min-height: 202mm !important;
                background-color: #FAFAFA !important;
            }

            /* ═══ WATERMARK ═══ */
            .luxury-watermark {
                position: absolute !important;
                top: 50% !important;
                left: 50% !important;
                transform: translate(-50%, -50%) rotate(-30deg) !important;
                font-size: 14rem !important;
                font-weight: 900 !important;
                color: #D4AF37 !important;
                opacity: 0.03 !important;
                white-space: nowrap !important;
                pointer-events: none !important;
                z-index: 1 !important;
                letter-spacing: -2px !important;
            }

            /* ═══ THE CERTIFICATE FRAME (ULTRA LUXURY) ═══ */
            .document-container::before {
                content: '';
                position: absolute !important;
                top: 5mm; bottom: 5mm; left: 5mm; right: 5mm;
                border: 2pt solid #1E3A8A !important;
                pointer-events: none !important;
                z-index: 50 !important;
            }
            .document-container::after {
                content: '';
                position: absolute !important;
                top: 6mm; bottom: 6mm; left: 6mm; right: 6mm;
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
                padding-bottom: 6px !important;
                margin-bottom: 12px !important;
            }
            .brand-name { font-size: 24px !important; font-weight: 900 !important; letter-spacing: -0.5px !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 2px !important; }
            .doc-title { font-size: 28px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #D4AF37 !important; line-height: 0.9 !important; }
            .title-sub { font-size: 9px !important; font-weight: 800 !important; letter-spacing: 2px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #D4AF37 !important; padding-top: 2px !important; margin-top: 2px !important; text-align: center !important; }
            
            /* ═══ INFO GRID ═══ */
            .info-grid {
                display: flex !important;
                justify-content: space-between !important;
                margin-bottom: 10px !important;
                background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important;
                padding: 6px 12px !important;
            }
            .info-group {
                display: flex !important;
                flex-direction: column !important;
                gap: 4px !important;
            }
            .info-item {
                display: flex !important;
                flex-direction: column !important;
            }

            /* ═══ TABLE ═══ */
            .luxury-table {
                width: 100% !important;
                border-collapse: collapse !important;
                margin-bottom: 10px !important;
            }
            .luxury-table th {
                background-color: #0F172A !important;
                color: #FFFFFF !important;
                padding: 6px 8px !important;
                font-weight: 600 !important;
                font-size: 12px !important;
                text-transform: uppercase !important;
                letter-spacing: 0.5px !important;
                border: none !important;
            }
            .luxury-table td {
                padding: 4px 6px !important;
                font-size: 12px !important;
                font-weight: 600 !important;
                border-bottom: 0.5pt solid #E5E7EB !important;
                color: #0F172A !important;
            }
            .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
            .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }

            /* ═══ TOTALS ═══ */
            .totals-section {
                display: flex !important;
                justify-content: flex-end !important;
                margin-bottom: 12px !important;
            }
            .totals-box {
                width: 250px !important;
                background: #F3F4F6 !important;
                border: 0.5pt solid #E5E7EB !important;
                border-top: 2pt solid #1E3A8A !important;
                padding: 8px !important;
            }
            .totals-row {
                display: flex !important;
                justify-content: space-between !important;
                margin-bottom: 4px !important;
                font-size: 11px !important;
                color: #4B5563 !important;
            }
            .totals-row.grand-total {
                margin-top: 6px !important;
                padding-top: 6px !important;
                border-top: 0.5pt solid #D1D5DB !important;
                font-size: 14px !important;
                font-weight: 900 !important;
                color: #1E3A8A !important;
            }
            
            /* ═══ CONDITIONS ═══ */
            .conditions-box {
                border: 0.5pt dashed #9CA3AF !important;
                background: #FFFFFF !important;
                padding: 8px !important;
                margin-top: 12px !important;
                font-size: 10px !important;
                color: #4B5563 !important;
            }
            .conditions-title {
                font-weight: 800 !important;
                color: #0F172A !important;
                margin-bottom: 4px !important;
            }


            /* ═══ FOOTER ═══ */
            .luxury-footer {
                margin-top: auto !important;
                text-align: center !important;
                font-size: 9px !important;
                color: #4B5563 !important;
                padding-top: 6px !important;
                page-break-inside: avoid !important;
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                gap: 2px !important;
            }
            .footer-line {
                width: 60px !important;
                height: 1pt !important;
                background-color: #D4AF37 !important;
                margin: 4px 0 !important;
            }
        }
      `}</style>

            <div className="document-container w-full mx-auto p-12 bg-[#FAFAFA] flex flex-col text-blue-950 print:p-0" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }}>

                <div className="luxury-watermark">{AZTA_IDENTITY.tradeNameAr}</div>

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
                                {brand?.name || (isArabic ? AZTA_IDENTITY.tradeNameAr : AZTA_IDENTITY.tradeNameEn)}
                                {(brand?.name || brand?.branchName) && brand?.name !== (isArabic ? AZTA_IDENTITY.tradeNameAr : AZTA_IDENTITY.tradeNameEn) && (
                                    <span className="text-sm font-normal text-slate-500 mr-2 print:text-[8px] font-sans">({brand?.name || brand?.branchName})</span>
                                )}
                            </h1>
                            <div className="mt-2 print:mt-1 flex gap-3 text-sm print:text-[6px] text-slate-600 font-bold">
                                {brand?.address && <span dir="ltr">Add: <span className="font-mono text-blue-950">{brand.address}</span></span>}
                                {brand?.contactNumber && <span dir="ltr">TEL: <span className="font-mono text-blue-950">{brand.contactNumber}</span></span>}
                                {brand?.vatNumber && <span dir="ltr">VAT: <span className="font-mono text-blue-950">{brand.vatNumber}</span></span>}
                            </div>
                        </div>
                    </div>

                    <div className={`text-center flex flex-col items-center flex-shrink-0 z-10 ${isArabic ? 'md:text-left rtl:text-left' : 'md:text-right rtl:text-right'}`}>
                        <h2 className="doc-title">{isArabic ? 'عرض سعر' : 'QUOTATION'}</h2>
                        <div className="title-sub">ESTIMATE</div>
                    </div>
                </div>

                {/* ▬▬▬ INFO SECTION ▬▬▬ */}
                <div className="info-grid relative z-10 mb-8 print:mb-4">
                    <div className="info-group">
                        <div className="info-item mb-2 print:mb-1">
                            <span className="font-thin-label">{isArabic ? 'العميل | Customer' : 'Customer'}</span>
                            <span className="font-bold-value text-gold">{customerName}</span>
                        </div>
                        <div className="info-item">
                            <span className="font-thin-label">{isArabic ? 'رقم الهاتف | Phone' : 'Phone'}</span>
                            <span className="font-bold-value text-charcoal tabular" dir="ltr">{customerPhone}</span>
                        </div>
                    </div>

                    <div className="info-group border-x border-slate-300 px-4 print:border-[#E5E7EB]">
                        <div className="info-item mb-2 print:mb-1">
                            <span className="font-thin-label">{isArabic ? 'رقم العرض | Quotation No.' : 'Quotation No.'}</span>
                            <span className="font-bold-value font-mono text-charcoal" dir="ltr">#{docNo}</span>
                        </div>
                        <div className="info-item">
                            <span className="font-thin-label">{isArabic ? 'التاريخ | Date' : 'Date'}</span>
                            <span className="font-bold-value font-mono tabular" dir="ltr">{new Date(order.createdAt || new Date()).toLocaleDateString('en-GB')}</span>
                        </div>
                    </div>

                    <div className="info-group border-l border-slate-300 pl-4 print:border-[#E5E7EB]">
                        <div className="info-item mb-2 print:mb-1">
                            <span className="font-thin-label">{isArabic ? 'صلاحية العرض | Validity' : 'Validity'}</span>
                            <span className="font-bold-value text-charcoal" dir="ltr">14 Days / يوم</span>
                        </div>
                        <div className="info-item">
                            <span className="font-thin-label">{isArabic ? 'العملة | Currency' : 'Currency'}</span>
                            <span className="font-bold-value text-charcoal tabular" dir="ltr">{currency}</span>
                        </div>
                    </div>
                </div>

                {/* ▬▬▬ TABLE ▬▬▬ */}
                <div className="relative z-10 w-full overflow-hidden mb-4 print:mb-2 min-h-[150px]">
                    <table className={`luxury-table print:w-full ${isArabic ? 'text-right' : 'text-left'}`}>
                        <thead>
                            <tr>
                                <th className="w-8 text-center" style={{ width: '5%' }}>م</th>
                                <th className={isArabic ? 'text-right' : 'text-left'} style={{ width: '45%' }}>{isArabic ? 'الصنف | Item Description' : 'Item Description'}</th>
                                <th className="text-center" style={{ width: '15%' }}>الكمية QTY</th>
                                <th className="text-center" style={{ width: '15%' }}>سعر الوحدة UNIT</th>
                                <th className="text-center" style={{ width: '20%' }}>الإجمالي TOTAL</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rawItems.length === 0 ? (
                                <tr>
                                    <td colSpan={5} className="py-4 text-center text-slate-400">{isArabic ? 'لا توجد أصناف' : 'No items'}</td>
                                </tr>
                            ) : (
                                rawItems.map((it: any, idx) => {
                                    const itemId = it.menuItem?.name || it.menuItemName || it.name || it.itemName || 'صنف';

                                    const qty = Number(it.quantity || 1);
                                    const price = Number(it.price || it.unitPrice || 0);
                                    const finalLineTotal = Number(it.totalPrice || it.lineTotal || (qty * price));

                                    return (
                                        <tr key={`${it.id || idx}`} style={{ pageBreakInside: 'avoid' }}>
                                            <td className="text-center tabular font-thin-label text-slate-600">{idx + 1}</td>
                                            <td>
                                                <div className="font-bold-value text-blue-950">{itemId}</div>
                                            </td>
                                            <td className="text-center tabular font-bold-value text-charcoal" dir="ltr">{qty}</td>
                                            <td className="text-center tabular text-charcoal" dir="ltr">{fmt(price)}</td>
                                            <td className="text-center tabular font-bold-value text-charcoal" dir="ltr">{fmt(finalLineTotal)}</td>
                                        </tr>
                                    );
                                })
                            )}
                        </tbody>
                    </table>
                </div>

                {/* ▬▬▬ TOTALS ▬▬▬ */}
                <div className="totals-section relative z-10">
                    <div className="totals-box">
                        <div className="totals-row">
                            <span>{isArabic ? 'الإجمالي قبل الخصم | Sub Total' : 'Sub Total'}</span>
                            <span className="tabular font-mono text-charcoal" dir="ltr">
                                {fmt((order.total || 0) + (order.discountAmount || 0))} {currency}
                            </span>
                        </div>
                        {(order.discountAmount || 0) > 0 && (
                            <div className="totals-row mt-1">
                                <span>{isArabic ? 'الخصم | Discount' : 'Discount'}</span>
                                <span className="tabular font-mono text-red-600" dir="ltr">
                                    -{fmt(order.discountAmount || 0)} {currency}
                                </span>
                            </div>
                        )}
                        <div className="totals-row grand-total mt-2 border-t border-slate-300 pt-2">
                            <span>{isArabic ? 'الإجمالي | Grand Total' : 'Grand Total'}</span>
                            <span className="tabular font-mono text-gold" dir="ltr">
                                {fmt(order.total || 0)} {currency}
                            </span>
                        </div>
                    </div>
                </div>

                {/* ▬▬▬ CONDITIONS ▬▬▬ */}
                <div className="conditions-box relative z-10">
                    <div className="conditions-title">{isArabic ? 'الشروط والأحكام | Terms & Conditions' : 'Terms & Conditions'}</div>
                    <div className="flex flex-col gap-1">
                        <p>- عرض السعر صالح لمدة 14 يوماً من تاريخ الإصدار ويخضع لتوافر الكميات في المخزون.</p>
                        <p>- الأسعار المعروضة قابلة للتغيير بعد انتهاء فترة الصلاحية أو عند تغير أسعار الصرف بشكل ملحوظ.</p>
                        <p>- هذا المستند لا يُعد فاتورة ضريبية رسمية، ولا يمكن استخدامه كإثبات للدفع.</p>
                    </div>
                </div>

                {/* ▬▬▬ FOOTER ▬▬▬ */}
                <div className="luxury-footer relative z-10 w-full font-mono mt-auto pt-4">
                    <div className="footer-line"></div>
                    <div className="font-bold-value text-gold mb-1 print:mb-0.5 mt-1 font-sans tracking-wide">نموذج نظام مرخص — LICENSED SYSTEM FORM</div>

                    <DocumentAuditFooter
                        audit={{ printedAt: new Date().toISOString(), generatedBy: brand?.name || 'AZTA ERP', ...(audit || {}) }}
                        extraRight={<div className="font-sans text-slate-400">{AZTA_IDENTITY.tradeNameAr}</div>}
                    />
                </div>

            </div>
        </div>
    );
}
