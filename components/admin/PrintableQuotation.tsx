import React from 'react';
import { AZTA_IDENTITY } from '../../config/identity';

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
    thermalPaperWidth?: '58mm' | '80mm';
}

const unitLabels: Record<string, string> = {
    piece: 'قطعة',
    kg: 'كجم',
    gram: 'جرام',
    liter: 'لتر',
    box: 'كرتون',
    pack: 'عبوة',
    meter: 'متر',
    ton: 'طن',
};

const PrintableQuotation: React.FC<PrintableQuotationProps> = ({
    data,
    language = 'ar',
    companyName,
    companyPhone,
    companyAddress,
    logoUrl,
    vatNumber,
    thermalPaperWidth = '58mm',
}) => {
    const resolvedCompanyName = companyName || '';
    const resolvedCompanyPhone = companyPhone || '';
    const resolvedCompanyAddress = companyAddress || '';
    const resolvedLogoUrl = logoUrl || '';
    const resolvedVatNumber = vatNumber || '';
    const resolvedThermalPaperWidth: '58mm' | '80mm' = thermalPaperWidth === '80mm' ? '80mm' : '58mm';
    const systemName = language === 'ar' ? AZTA_IDENTITY.tradeNameAr : AZTA_IDENTITY.tradeNameEn;
    const branchName = resolvedCompanyName.trim();
    const showBranchName = Boolean(branchName) && branchName !== systemName.trim();

    const currencyLabel = data.currency || '—';
    const formatAmount = (value: number) => {
        const n = Number(value) || 0;
        try {
            return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        } catch {
            return n.toFixed(2);
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
        <div className="thermal-invoice" dir="rtl">
            <style>{`
                .thermal-invoice {
                    font-family: 'Tahoma', 'Arial', sans-serif;
                    font-size: 12px;
                    line-height: 1.4;
                    color: #000;
                    width: ${resolvedThermalPaperWidth};
                    max-width: ${resolvedThermalPaperWidth};
                    margin: 0 auto;
                    padding: 0 2px;
                }
                .text-center { text-align: center; }
                .text-right { text-align: right; }
                .text-left { text-align: left; }
                .font-bold { font-weight: bold; }
                .text-xs { font-size: 10px; }
                .text-sm { font-size: 11px; }
                .text-lg { font-size: 14px; }
                .text-xl { font-size: 16px; }
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
                .logo-img { height: 40px; margin-bottom: 5px; display: block; margin-left: auto; margin-right: auto; }
                table { width: 100%; border-collapse: collapse; }
                th { text-align: right; font-size: 10px; border-bottom: 1px dashed #000; padding-bottom: 4px; }
                td { padding: 4px 0; vertical-align: top; }
                .item-name { font-weight: bold; margin-bottom: 2px; }
                .item-meta { font-size: 10px; color: #444; }
                .total-box { border: 2px solid #000; padding: 8px; margin-top: 10px; border-radius: 4px; }
                .validity-box {
                    border: 1px dashed #888;
                    padding: 6px 8px;
                    margin-top: 8px;
                    border-radius: 4px;
                    text-align: center;
                    font-size: 10px;
                }
            `}</style>

            {/* Header — same as invoice */}
            <div className="text-center mb-2">
                {resolvedLogoUrl && <img src={resolvedLogoUrl} alt="Logo" className="logo-img" />}
                <div className="font-bold text-lg mb-1">{systemName}</div>
                {showBranchName && <div className="text-sm mb-1">{branchName}</div>}
                <div className="text-xs">{resolvedCompanyAddress}</div>
                {resolvedCompanyPhone && <div className="text-xs" dir="ltr">{resolvedCompanyPhone}</div>}
                {resolvedVatNumber && <div className="text-xs mt-1 font-bold">الرقم الضريبي: <span dir="ltr" className="tabular">{resolvedVatNumber}</span></div>}
            </div>

            {/* Title — عرض سعر */}
            <div className="text-center border-y py-1 mb-2">
                <div className="font-bold text-lg">عرض سعر</div>
                <div className="text-xs">Price Quotation</div>
            </div>

            {/* Quotation info */}
            <div className="mb-2 text-sm">
                <div className="flex">
                    <span>رقم العرض:</span>
                    <span className="font-bold tabular" dir="ltr">{data.quotationNumber}</span>
                </div>
                <div className="flex">
                    <span>التاريخ:</span>
                    <span className="tabular" dir="ltr">{formatDate(data.createdAt)}</span>
                </div>
                <div className="flex">
                    <span>صالح حتى:</span>
                    <span className="tabular" dir="ltr">{formatDate(data.validUntil)}</span>
                </div>
                <div className="flex">
                    <span>العميل:</span>
                    <span className="font-bold">{data.customerName || '—'}</span>
                </div>
                {data.customerCompany && (
                    <div className="flex">
                        <span>الشركة:</span>
                        <span>{data.customerCompany}</span>
                    </div>
                )}
                {data.customerPhone && (
                    <div className="flex">
                        <span>الهاتف:</span>
                        <span className="tabular" dir="ltr">{data.customerPhone}</span>
                    </div>
                )}
                {data.customerAddress && (
                    <div className="flex">
                        <span>العنوان:</span>
                        <span>{data.customerAddress}</span>
                    </div>
                )}
            </div>

            {/* Items table */}
            <table className="mb-2">
                <thead>
                    <tr>
                        <th style={{ width: '5%', textAlign: 'center' }}>#</th>
                        <th style={{ width: '35%' }}>الصنف</th>
                        <th style={{ width: '12%', textAlign: 'center' }}>الوحدة</th>
                        <th style={{ width: '12%', textAlign: 'center' }}>الكمية</th>
                        <th style={{ width: '18%', textAlign: 'center' }}>السعر</th>
                        <th style={{ width: '18%', textAlign: 'left' }}>المجموع</th>
                    </tr>
                </thead>
                <tbody>
                    {data.items.map((item, index) => (
                        <tr key={index}>
                            <td className="text-center text-xs">{index + 1}</td>
                            <td>
                                <div className="item-name">{item.itemName}</div>
                                {item.notes && <div className="item-meta">{item.notes}</div>}
                            </td>
                            <td className="text-center text-xs">{unitLabels[item.unit] || item.unit}</td>
                            <td className="text-center tabular">{item.quantity}</td>
                            <td className="text-center tabular">{formatAmount(item.unitPrice)}</td>
                            <td className="text-left font-bold tabular">{formatAmount(item.total)}</td>
                        </tr>
                    ))}
                </tbody>
            </table>

            {/* Totals — same structure as invoice */}
            <div className="border-t pt-2 mb-2">
                <div className="flex mb-1">
                    <span>المجموع الفرعي:</span>
                    <span className="tabular">{formatAmount(data.subtotal)}</span>
                </div>
                {data.discountAmount > 0 && (
                    <div className="flex mb-1">
                        <span>الخصم{data.discountType === 'percentage' ? ` (${data.discountValue}%)` : ''}:</span>
                        <span className="tabular">- {formatAmount(data.discountAmount)}</span>
                    </div>
                )}
                {data.taxAmount > 0 && (
                    <div className="flex mb-1">
                        <span>الضريبة ({data.taxRate}%):</span>
                        <span className="tabular">{formatAmount(data.taxAmount)}</span>
                    </div>
                )}
            </div>

            {/* Grand total box — same as invoice */}
            <div className="total-box text-center mb-4">
                <div className="text-sm font-bold mb-1">الإجمالي النهائي</div>
                <div className="text-xl font-bold tabular" dir="ltr">{formatAmount(data.total)} {currencyLabel}</div>
            </div>

            {/* Terms */}
            {data.terms && (
                <div className="mb-2 text-sm border-b pb-2">
                    <div className="font-bold mb-1">الشروط والأحكام:</div>
                    <div className="text-xs" style={{ whiteSpace: 'pre-wrap' }}>{data.terms}</div>
                </div>
            )}

            {/* Notes */}
            {data.notes && (
                <div className="mb-2 text-sm">
                    <div className="font-bold mb-1">ملاحظات:</div>
                    <div className="text-xs" style={{ whiteSpace: 'pre-wrap' }}>{data.notes}</div>
                </div>
            )}

            {/* Validity notice */}
            <div className="validity-box">
                هذا العرض صالح حتى {formatDate(data.validUntil)} — الأسعار قابلة للتغيير بعد انتهاء الصلاحية
            </div>

            {/* Footer — same as invoice */}
            <div className="text-center text-xs mt-2">
                <div className="font-bold">شكراً لثقتكم!</div>
                <div className="mt-1 tabular" dir="ltr">{new Date().toLocaleString('en-GB')}</div>
            </div>
        </div>
    );
};

export default PrintableQuotation;
