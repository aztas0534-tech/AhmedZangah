import React, { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { PurchaseOrder } from '../../../types';
import { AZTA_IDENTITY } from '../../../config/identity';
import { localizeUomCodeAr } from '../../../utils/displayLabels';
import { DocumentAuditInfo } from '../../../utils/documentStandards';

// Helper to generate TLV base64 for ZATCA QR
const generateZatcaTLV = (sellerName: string, vatRegistrationNumber: string, timestamp: string, total: string, vatTotal: string) => {
    const simpleTLV = (tag: number, value: string) => {
        const utf8Encoder = new TextEncoder();
        const valueBytes = utf8Encoder.encode(value);
        const len = valueBytes.length;
        const tagByte = new Uint8Array([tag]);
        const lenByte = new Uint8Array([len]);
        const combined = new Uint8Array(tagByte.length + lenByte.length + valueBytes.length);
        combined.set(tagByte);
        combined.set(lenByte, tagByte.length);
        combined.set(valueBytes, tagByte.length + lenByte.length);
        return combined;
    };

    const tags = [
        simpleTLV(1, sellerName),
        simpleTLV(2, vatRegistrationNumber),
        simpleTLV(3, timestamp),
        simpleTLV(4, total),
        simpleTLV(5, vatTotal)
    ];

    const totalLength = tags.reduce((acc, curr) => acc + curr.length, 0);
    const result = new Uint8Array(totalLength);
    let offset = 0;
    tags.forEach(tag => {
        result.set(tag, offset);
        offset += tag.length;
    });

    let binary = '';
    const len = result.byteLength;
    for (let i = 0; i < len; i++) {
        binary += String.fromCharCode(result[i]);
    }
    return window.btoa(binary);
};

interface Brand {
    name?: string;
    address?: string;
    contactNumber?: string;
    logoUrl?: string;
    branchName?: string;
    branchCode?: string;
    vatNumber?: string;
}

export default function PrintablePurchaseOrder({
    order,
    brand,
    language = 'ar',
    documentStatus,
    referenceId,
    audit,
    printNumber
}: {
    order: PurchaseOrder;
    brand?: Brand;
    language?: 'ar' | 'en';
    documentStatus?: string;
    referenceId?: string;
    audit?: DocumentAuditInfo | null;
    printNumber?: number | null;
}) {
    const docNo = order.poNumber || `PO-${order.id.slice(-6).toUpperCase()}`;
    const currency = String(order.currency || '').toUpperCase() || '—';
    const fx = Number(order.fxRate || 0);
    const items = Array.isArray(order.items) ? order.items : [];

    const resolvedCompanyName = brand?.name || AZTA_IDENTITY.tradeNameAr;
    const resolvedCompanyPhone = brand?.contactNumber || '';
    const resolvedCompanyAddress = brand?.address || '';
    const resolvedLogoUrl = brand?.logoUrl || '';
    const resolvedVatNumber = brand?.vatNumber || '';
    const systemName = AZTA_IDENTITY.tradeNameAr;
    const branchName = resolvedCompanyName.trim();
    const showBranchName = Boolean(branchName) && branchName !== systemName.trim();

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
        if (lower === 'pack' || lower === 'pkt') return 'عبوة';
        if (lower === 'bottle') return 'زجاجة';
        if (lower === 'kg') return 'كجم';
        if (lower === 'gram' || lower === 'g') return 'جرام';
        if (lower === 'bag') return 'كيس';
        if (lower === 'bundle') return 'ربطة';
        return raw;
    };

    const currencyLabelAr = (codeRaw: string) => {
        const c = String(codeRaw || '').trim().toUpperCase();
        if (!c || c === '—') return 'عملة';
        if (c === 'SAR') return 'ريال سعودي';
        if (c === 'YER') return 'ريال يمني';
        if (c === 'USD') return 'دولار أمريكي';
        if (c === 'EUR') return 'يورو';
        if (c === 'GBP') return 'جنيه إسترليني';
        if (c === 'AED') return 'درهم إماراتي';
        if (c === 'KWD') return 'دينار كويتي';
        if (c === 'BHD') return 'دينار بحريني';
        if (c === 'OMR') return 'ريال عُماني';
        if (c === 'QAR') return 'ريال قطري';
        return 'عملة';
    };

    const formatAmount = (value: number) => {
        const n = Number(value) || 0;
        try {
            return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        } catch {
            return n.toFixed(2);
        }
    };

    // Subtotal and Total calculations
    const calcSubtotal = items.reduce((sum, item) => sum + (Number(item.quantity) * Number(item.unitCost || 0)), 0);
    const calcTax = Number(order.taxAmount || 0);
    const calcDiscount = Number(order.discountAmount || 0);
    const calcDelivery = Number(order.deliveryFee || 0); // POs typically don't have delivery fees but keeping for parity
    const calcTotal = calcSubtotal - calcDiscount + calcTax + calcDelivery;

    const qrData = generateZatcaTLV(
        systemName,
        resolvedVatNumber,
        order.purchaseDate || new Date().toISOString(),
        calcTotal.toFixed(2),
        calcTax.toFixed(2)
    );

    const printedBy = String(audit?.printedBy || '').trim();
    const typeLabel = 'مشتريات';

    const copyTitle = !printNumber || printNumber === 1
        ? 'أمر شراء'
        : printNumber === 2
            ? 'نسخة الإدارة'
            : 'نسخة الحسابات';

    const thermalPaperWidth = '80mm';

    return (
        <div className="thermal-invoice" dir="rtl">
            <style>{`
                .thermal-invoice {
                    font-family: 'Tahoma', 'Arial', sans-serif;
                    font-size: 12px;
                    line-height: 1.4;
                    color: #000;
                    width: ${thermalPaperWidth};
                    max-width: ${thermalPaperWidth};
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
                .logo-img { height: 100px; margin-bottom: 5px; display: block; margin-left: auto; margin-right: auto; }
                table { width: 100%; border-collapse: collapse; }
                th { text-align: right; font-size: 11px; border-bottom: 1px dashed #000; padding-bottom: 4px; }
                td { padding: 3px 0; vertical-align: top; }
                .item-name { font-weight: bold; margin-bottom: 2px; }
                .item-meta { font-size: 10px; color: #444; }
                .total-box { border: 2px solid #000; padding: 8px; margin-top: 10px; border-radius: 4px; }
                .watermark { 
                    position: fixed; top: 30%; left: 50%; transform: translate(-50%, -50%) rotate(-45deg);
                    font-size: 40px; font-weight: bold; color: rgba(0,0,0,0.1); pointer-events: none; z-index: 0; border: 4px solid rgba(0,0,0,0.1); padding: 10px 40px;
                }
            `}</style>

            {printNumber && printNumber > 1 && (
                <div className="watermark">{copyTitle}</div>
            )}

            <div className="text-center mb-2">
                {resolvedLogoUrl && <img src={resolvedLogoUrl} alt="Logo" className="logo-img" />}
                <div className="font-bold text-lg mb-1">{systemName}</div>
                {showBranchName && <div className="text-sm mb-1">{branchName}</div>}
                <div className="text-xs">{resolvedCompanyAddress}</div>
                {resolvedCompanyPhone && <div className="text-xs" dir="ltr">{resolvedCompanyPhone}</div>}
                {resolvedVatNumber && <div className="text-xs mt-1 font-bold">الرقم الضريبي: <span dir="ltr" className="tabular">{resolvedVatNumber}</span></div>}
            </div>

            <div className="text-center border-y py-1 mb-2">
                <div className="font-bold text-lg">أمر شراء (PO)</div>
                <div className="inline-block border border-black rounded px-2 py-0.5 mt-1 text-sm font-bold bg-gray-100">{copyTitle}</div>
                <div className="text-xs mt-1">النوع: {typeLabel}</div>
            </div>

            <div className="mb-2 text-sm">
                <div className="flex">
                    <span>رقم الأمر:</span>
                    <span className="font-bold tabular" dir="ltr">{docNo}</span>
                </div>
                <div className="flex">
                    <span>التاريخ:</span>
                    <span className="tabular" dir="ltr">{new Date(order.purchaseDate || order.createdAt || new Date()).toLocaleDateString('en-GB')} {new Date(order.purchaseDate || order.createdAt || new Date()).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false })}</span>
                </div>
                <div className="flex">
                    <span>المورد:</span>
                    <span className="font-bold">{order.supplierName || 'غير محدد'}</span>
                </div>
                {order.referenceNumber && (
                    <div className="flex">
                        <span>فاتورة المورد:</span>
                        <span className="tabular" dir="ltr">{order.referenceNumber}</span>
                    </div>
                )}
                {order.warehouseName && (
                    <div className="flex">
                        <span>المستودع:</span>
                        <span>{order.warehouseName}</span>
                    </div>
                )}
            </div>

            <table className="mb-2">
                <thead>
                    <tr>
                        <th style={{ width: '14%' }}>رقم الصنف</th>
                        <th style={{ width: '38%' }}>البيان</th>
                        <th style={{ width: '13%', textAlign: 'center' }}>الكمية</th>
                        <th style={{ width: '15%', textAlign: 'center' }}>السعر</th>
                        <th style={{ width: '20%', textAlign: 'left' }}>الإجمالي</th>
                    </tr>
                </thead>
                <tbody>
                    {items.map((item, index) => {
                        const itemNo = (() => {
                            const rawId = String((item as any)?.item_id || '').trim();
                            if (!rawId) return '—';
                            return rawId.replace(/-/g, '').slice(-6).toUpperCase();
                        })();
                        const soldUnit = uomLabel(String((item as any)?.uomCode || (item as any)?.unit_type || 'piece'));
                        const soldQty = Number(item.quantity) || 0;
                        const invoiceCurrencyLabel = currencyLabelAr(currency);
                        const soldUnitPrice = Number(item.unitCost) || 0;
                        const lineTotal = soldQty * soldUnitPrice;

                        return (
                            <tr key={index}>
                                <td className="tabular" dir="ltr">{itemNo}</td>
                                <td>
                                    <div className="item-name">{item.itemName || 'صنف غير معروف'}</div>
                                    <div className="item-meta">
                                        <span>الوحدة: {soldUnit}</span>
                                    </div>
                                </td>
                                <td className="text-center tabular" dir="ltr">{soldQty}</td>
                                <td className="text-center tabular" dir="ltr">{formatAmount(soldUnitPrice)}</td>
                                <td className="text-left font-bold tabular" dir="ltr">{formatAmount(lineTotal)}</td>
                            </tr>
                        );
                    })}
                </tbody>
            </table>

            <div className="border-t pt-2 mb-2">
                <div className="flex mb-1">
                    <span>المجموع الفرعي:</span>
                    <span className="tabular" dir="ltr">
                        {formatAmount(calcSubtotal)} {currencyLabelAr(currency)}
                    </span>
                </div>
                {calcDiscount > 0 && (
                    <div className="flex mb-1">
                        <span>الخصم:</span>
                        <span className="tabular" dir="ltr">
                            - {formatAmount(calcDiscount)} {currencyLabelAr(currency)}
                        </span>
                    </div>
                )}
                <div className="flex mb-1">
                    <span>الضريبة (15%):</span>
                    <span className="tabular" dir="ltr">
                        {formatAmount(calcTax)} {currencyLabelAr(currency)}
                    </span>
                </div>
            </div>

            <div className="total-box text-center mb-4">
                <div className="text-sm font-bold mb-1">الإجمالي النهائي</div>
                <div className="text-xl font-bold tabular" dir="ltr">
                    {formatAmount(calcTotal)} {currencyLabelAr(currency)}
                </div>
            </div>

            <div className="mb-4 text-sm border-b pb-2">
                {String((order as any)?.currency || '').trim() ? (
                    <div className="flex mt-1">
                        <span>العملة:</span>
                        <span className="tabular" dir="ltr">{String((order as any).currency || '').toUpperCase()}</span>
                    </div>
                ) : null}
                {fx > 0 ? (
                    <div className="flex mt-1">
                        <span>سعر الصرف:</span>
                        <span className="tabular" dir="ltr">{formatAmount(fx)}</span>
                    </div>
                ) : null}
            </div>

            <div className="text-center mb-4">
                <div style={{ display: 'inline-block', padding: '5px', background: 'white' }}>
                    {qrData && <QRImage value={qrData} size={120} />}
                </div>
                <div className="text-xs mt-1">امسح للتحقق (ZATCA)</div>
            </div>

            <div className="mb-3 text-xs">
                <div className="border border-black rounded-md p-2">
                    <div className="mt-2 flex justify-between">
                        <div>توقيع المستلم:</div>
                        <div style={{ width: 120, borderBottom: '1px solid #000' }} />
                    </div>
                </div>
            </div>

            <div className="text-center text-xs mt-2">
                <div className="mt-1 tabular" dir="ltr">{new Date().toLocaleString('en-GB')}</div>
                <div className="mt-1">
                    <span className="tabular" dir="ltr">Ref: {referenceId || order.id.slice(-8).toUpperCase()}</span>
                    {printedBy ? (
                        <>
                            <span> • </span>
                            <span>طبع بواسطة: {printedBy}</span>
                        </>
                    ) : null}
                    {printNumber && printNumber > 0 ? (
                        <>
                            <span> • </span>
                            <span className="tabular" dir="ltr">{`نسخة رقم ${printNumber}`}</span>
                        </>
                    ) : null}
                </div>
            </div>
        </div>
    );
}

const QRImage: React.FC<{ value: string; size?: number }> = ({ value, size = 120 }) => {
    const [url, setUrl] = useState<string>('');
    useEffect(() => {
        let active = true;
        (async () => {
            try {
                const dataUrl = await QRCode.toDataURL(value, { width: size, margin: 1 });
                if (active) setUrl(dataUrl);
            } catch {
                if (active) setUrl('');
            }
        })();
        return () => { active = false; };
    }, [value, size]);
    if (!url) return null;
    return <img src={url} alt="QR" style={{ width: size, height: size }} />;
};
