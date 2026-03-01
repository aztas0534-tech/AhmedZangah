import { forwardRef, useEffect, useMemo, useState } from 'react';
import { Order, AppSettings, CartItem } from '../types';
import { useDeliveryZones } from '../contexts/DeliveryZoneContext';
import QRCode from 'qrcode';
import { generateZatcaTLV } from './admin/PrintableInvoice';
import { AZTA_IDENTITY } from '../config/identity';
import { useItemMeta } from '../contexts/ItemMetaContext';
import { localizeUomCodeAr } from '../utils/displayLabels';
import { useWarehouses } from '../contexts/WarehouseContext';

interface InvoiceProps {
    order: Order;
    settings: AppSettings;
    branding?: {
        name?: string;
        address?: string;
        contactNumber?: string;
        logoUrl?: string;
    };
    costCenterLabel?: string | null;
    creditSummary?: { previousBalance: number; invoiceAmount: number; newBalance: number; currencyCode: string } | null;
    audit?: { printedBy?: string | null } | null;
    copyLabel?: string;
    accentColor?: string;
    id?: string;
}

const Invoice = forwardRef<HTMLDivElement, InvoiceProps>(({ order, settings, branding, costCenterLabel, creditSummary, audit, copyLabel, accentColor, id }, ref) => {
    const lang = 'ar';
    const { getDeliveryZoneById } = useDeliveryZones();
    const { getWarehouseById } = useWarehouses();
    const invoiceSnapshot = order.invoiceSnapshot;
    const invoiceOrder = invoiceSnapshot
        ? {
            ...order,
            createdAt: invoiceSnapshot.createdAt,
            deliveryZoneId: invoiceSnapshot.deliveryZoneId,
            items: invoiceSnapshot.items,
            subtotal: invoiceSnapshot.subtotal,
            deliveryFee: invoiceSnapshot.deliveryFee,
            discountAmount: invoiceSnapshot.discountAmount,
            total: invoiceSnapshot.total,
            taxAmount: (invoiceSnapshot as any).taxAmount,
            taxRate: (invoiceSnapshot as any).taxRate,
            currency: (invoiceSnapshot as any).currency,
            fxRate: (invoiceSnapshot as any).fxRate,
            baseTotal: (invoiceSnapshot as any).baseTotal,
            paymentMethod: invoiceSnapshot.paymentMethod,
            customerName: invoiceSnapshot.customerName,
            phoneNumber: invoiceSnapshot.phoneNumber,
            address: invoiceSnapshot.address,
            invoiceIssuedAt: invoiceSnapshot.issuedAt,
            invoiceNumber: invoiceSnapshot.invoiceNumber,
            orderSource: invoiceSnapshot.orderSource,
            invoiceTerms: invoiceSnapshot.invoiceTerms ?? (order as any).invoiceTerms,
            netDays: invoiceSnapshot.netDays ?? (order as any).netDays,
            dueDate: invoiceSnapshot.dueDate ?? (order as any).dueDate,
            paymentBreakdown: (invoiceSnapshot as any).paymentBreakdown ?? (order as any).paymentBreakdown,
        }
        : order;

    // Safety check: Ensure items is an array to prevent .map() crashes
    if (!Array.isArray(invoiceOrder.items)) {
        invoiceOrder.items = [];
    }
    const deliveryZone = invoiceOrder.deliveryZoneId ? getDeliveryZoneById(invoiceOrder.deliveryZoneId) : undefined;
    const systemName = lang === 'ar' ? AZTA_IDENTITY.tradeNameAr : AZTA_IDENTITY.tradeNameEn;
    const systemKey = AZTA_IDENTITY.merchantKey;
    const branchName = (branding?.name || '').trim();
    const showBranchName = Boolean(branchName) && branchName !== systemName;
    const storeAddress = branding?.address ?? settings.address;
    const storeContactNumber = branding?.contactNumber ?? settings.contactNumber;
    const storeLogoUrl = branding?.logoUrl ?? settings.logoUrl;
    const isCopy = (invoiceOrder.invoicePrintCount || 0) > 0;
    const invoiceDate = invoiceOrder.invoiceIssuedAt || invoiceOrder.createdAt;
    const invoiceTerms: 'cash' | 'credit' = (invoiceOrder as any).invoiceTerms === 'credit' || invoiceOrder.paymentMethod === 'ar' ? 'credit' : 'cash';
    const invoiceTermsLabel = invoiceTerms === 'credit' ? 'أجل' : 'نقد';
    const invoiceDueDate = typeof (invoiceOrder as any).dueDate === 'string' ? String((invoiceOrder as any).dueDate) : '';
    const printedBy = String(audit?.printedBy || '').trim();
    const fmtByCode = (value: number, code: string) => {
        const c = String(code || '').trim().toUpperCase();
        const dp = c === 'YER' ? 0 : 2;
        const n = Number(value) || 0;
        try {
            return n.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
        } catch {
            return n.toFixed(dp);
        }
    };
    const currencyCode = String((invoiceOrder as any).currency || '').toUpperCase() || '—';
    const vatNumber = (settings.taxSettings?.taxNumber || '').trim();
    const taxAmount = Number((invoiceOrder as any).taxAmount) || 0;
    const issueIso = String(invoiceDate || new Date().toISOString());
    const { getUnitLabel } = useItemMeta();
    const isDense = invoiceOrder.items.length >= 18;

    const computeInvoiceLine = (item: CartItem, mode: 'base_unit' | 'sold_uom') => {
        const addonsArray = Object.values(item.selectedAddons || {});
        const addonsPrice = addonsArray.reduce((sum, { addon, quantity }: any) => sum + (Number(addon?.price) || 0) * (Number(quantity) || 0), 0);
        const unitType = String((item as any).unitType || (item as any).unit || 'piece');
        const isWeightBased = unitType === 'kg' || unitType === 'gram';

        let itemPrice = Number((item as any).price) || 0;
        let soldQty = Number((item as any).quantity) || 0;
        if (isWeightBased) {
            soldQty = typeof (item as any).weight === 'number' ? Number((item as any).weight) || 0 : soldQty;
            if (unitType === 'gram' && (item as any).pricePerUnit) {
                itemPrice = (Number((item as any).pricePerUnit) || 0) / 1000;
            }
        }

        const factor = isWeightBased ? 1 : (Number((item as any)?.uomQtyInBase || 1) || 1);
        const baseUnitPrice = itemPrice + addonsPrice;
        const qtyForLine = isWeightBased ? soldQty : (mode === 'base_unit' ? (soldQty * factor) : soldQty);
        const lineTotal = baseUnitPrice * qtyForLine;
        const displayUnitPrice = isWeightBased ? baseUnitPrice : (mode === 'base_unit' ? (baseUnitPrice * factor) : baseUnitPrice);

        return { addonsArray, isWeightBased, unitType, factor, soldQty, baseUnitPrice, displayUnitPrice, lineTotal };
    };

    const formatMoney = (v: number) => {
        const n = Number(v || 0);
        if (!Number.isFinite(n)) return '0.00';
        return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
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

    const invoiceCurrencyLabel = currencyLabelAr(currencyCode);
    const invoiceWarehouseId = String((invoiceOrder as any)?.warehouseId || '').trim();
    const invoiceWarehouseName = useMemo(() => {
        if (!invoiceWarehouseId) return '';
        const w = getWarehouseById(invoiceWarehouseId);
        if (w?.name) return String(w.name);
        return invoiceWarehouseId.slice(-6);
    }, [getWarehouseById, invoiceWarehouseId]);

    const getItemNumber = (item: CartItem) => {
        const rawBarcode = String((item as any)?.barcode || '').trim();
        if (rawBarcode) return rawBarcode;
        const rawId = String(item?.id || '').trim();
        if (!rawId) return '—';
        return rawId.replace(/-/g, '').slice(-6).toUpperCase();
    };

    const safeUomLabelAr = (codeOrName: string) => {
        const raw = String(codeOrName || '').trim();
        if (!raw) return 'وحدة';
        const hasArabic = /[\u0600-\u06FF]/.test(raw);
        if (hasArabic) return raw;
        const unitTypeLabel = getUnitLabel(raw as any, 'ar');
        if (unitTypeLabel && /[\u0600-\u06FF]/.test(String(unitTypeLabel))) {
            return String(unitTypeLabel);
        }
        const mapped = localizeUomCodeAr(raw);
        if (!mapped || mapped === '—') return 'وحدة';
        if (String(mapped).trim() === raw) {
            const lower = raw.toLowerCase();
            if (
                lower === 'piece' || lower === 'pcs' || lower === 'pc' ||
                lower === 'pack' || lower === 'pkt' ||
                lower === 'carton' || lower === 'ctn' ||
                lower === 'box' ||
                lower === 'bottle' ||
                lower === 'kg' ||
                lower === 'gram' || lower === 'g'
            ) {
                return mapped;
            }
            return 'وحدة';
        }
        return mapped;
    };

    type InvoiceLinePricing = {
        isWeightBased: boolean;
        unitType?: string;
        soldQty: number;
    };

    const getSoldUnitLabelAr = (item: CartItem, pricing: InvoiceLinePricing) => {
        if (pricing.isWeightBased) return safeUomLabelAr(String(pricing.unitType || 'kg'));
        const uomCode = String((item as any)?.uomCode || '').trim();
        if (uomCode) return safeUomLabelAr(uomCode);
        const baseUnit = String((item as any)?.baseUnit || (item as any)?.base_unit || '').trim();
        if (baseUnit) return safeUomLabelAr(baseUnit);
        if (pricing.unitType) return safeUomLabelAr(String(pricing.unitType));
        const unitTypeLabel = getUnitLabel((item as any)?.unitType, 'ar');
        return unitTypeLabel ? safeUomLabelAr(unitTypeLabel) : 'وحدة';
    };

    const getSoldQuantityTextAr = (item: CartItem, pricing: InvoiceLinePricing) => {
        if (pricing.isWeightBased) return String(pricing.soldQty);
        return String(item.quantity);
    };

    const qrValue = useMemo(() => {
        if (!vatNumber) return '';
        const total = (Number(invoiceOrder.total) || 0).toFixed(2);
        const vatTotal = taxAmount.toFixed(2);
        return generateZatcaTLV(systemName || systemKey || '—', vatNumber, issueIso, total, vatTotal);
    }, [issueIso, invoiceOrder.total, systemKey, systemName, taxAmount, vatNumber]);

    const invoicePricingMode = useMemo<'base_unit' | 'sold_uom'>(() => {
        const targetSubtotal = Number((invoiceOrder as any)?.subtotal) || 0;
        if (!(targetSubtotal > 0) || !Array.isArray(invoiceOrder.items) || invoiceOrder.items.length === 0) {
            return 'base_unit';
        }
        const sumBase = invoiceOrder.items.reduce((sum: number, item: any) => sum + (computeInvoiceLine(item as CartItem, 'base_unit').lineTotal || 0), 0);
        const sumUom = invoiceOrder.items.reduce((sum: number, item: any) => sum + (computeInvoiceLine(item as CartItem, 'sold_uom').lineTotal || 0), 0);
        const diffBase = Math.abs(sumBase - targetSubtotal);
        const diffUom = Math.abs(sumUom - targetSubtotal);
        return diffUom + 0.01 < diffBase ? 'sold_uom' : 'base_unit';
    }, [invoiceOrder.items, (invoiceOrder as any)?.subtotal]);

    const [qrUrl, setQrUrl] = useState<string>('');

    useEffect(() => {
        let active = true;
        if (!qrValue) {
            setQrUrl('');
            return;
        }
        (async () => {
            try {
                const dataUrl = await QRCode.toDataURL(qrValue, { width: 160, margin: 1 });
                if (active) setQrUrl(dataUrl);
            } catch {
                if (active) setQrUrl('');
            }
        })();
        return () => {
            active = false;
        };
    }, [qrValue]);

    const getPaymentMethodName = (method: string) => {
        const methods: Record<string, string> = {
            'cash': 'نقدًا',
            'network': 'حوالات',
            'kuraimi': 'حسابات بنكية',
            'card': 'حوالات',
            'bank': 'حسابات بنكية',
            'bank_transfer': 'حسابات بنكية',
            'online': 'حوالات',
            'ar': 'آجل'
        };
        return methods[method] || 'غير معروف';
    };

    return (
        <div ref={ref} className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0" dir="rtl">
            <style>{`
                @media print {
                    @page { size: A4; margin: 0; }
                    body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
                    .invoice-container { 
                        width: 100% !important; 
                        max-width: none !important; 
                        margin: 0 auto !important; 
                        padding: 10mm 12mm !important;
                        box-sizing: border-box;
                        gap: 16px !important;
                        display: block !important;
                    }
                    .invoice-header {
                        padding-bottom: 12px !important;
                        margin-bottom: 16px !important;
                        border-bottom-width: 3px !important;
                        border-color: #0f172a !important;
                        page-break-inside: avoid;
                    }
                    .invoice-title {
                        font-size: 36px !important;
                        line-height: 1 !important;
                        color: #0f172a !important;
                    }
                    .brand-name {
                        font-size: 28px !important;
                        color: #0f172a !important;
                    }
                    .invoice-meta {
                        gap: 16px !important;
                        margin-bottom: 16px !important;
                        page-break-inside: avoid;
                    }
                    .meta-card {
                        padding: 12px !important;
                        border: 1px solid #cbd5e1 !important;
                        background: #f8fafc !important;
                    }
                    .invoice-items {
                        margin-bottom: 16px !important;
                        border: 1px solid #cbd5e1 !important;
                        border-radius: 8px !important;
                    }
                    .invoice-items table {
                        font-size: 11px !important;
                        page-break-inside: auto;
                    }
                    .invoice-items thead {
                        display: table-header-group;
                    }
                    .invoice-items tr {
                        page-break-inside: avoid;
                        page-break-after: auto;
                    }
                    .invoice-items th {
                        background-color: #0f172a !important;
                        color: white !important;
                        padding: 8px 6px !important;
                        font-size: 11px !important;
                    }
                    .invoice-items td {
                        padding: 6px !important;
                        border-bottom: 1px solid #e2e8f0 !important;
                    }
                    .totals-box {
                        background-color: #f1f5f9 !important;
                        color: #0f172a !important;
                        border: 2px solid #0f172a !important;
                        padding: 16px !important;
                        page-break-inside: avoid;
                    }
                    .totals-box .text-white {
                        color: #0f172a !important;
                    }
                    .totals-box .bg-slate-700 {
                        background-color: #cbd5e1 !important;
                    }
                    .credit-summary-box {
                        background-color: #fff !important;
                        border: 2px solid #e2e8f0 !important;
                        page-break-inside: avoid;
                    }
                    .qr-section {
                        border: 1px solid #e2e8f0 !important;
                        background: #fff !important;
                        page-break-inside: avoid;
                    }
                }
            `}</style>
            <div className={`invoice-container w-full mx-auto p-12 bg-white flex flex-col gap-6 text-slate-900 print:p-4 print:pt-6 print:gap-2`} style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }} id={id}>
                {/* Watermark for Copy */}
                {(isCopy || copyLabel) && (
                    <div className="pointer-events-none absolute inset-0 flex items-center justify-center overflow-hidden z-0">
                        <div className="text-gray-100 font-black text-[10rem] print:text-[6rem] -rotate-45 select-none opacity-40 print:opacity-30" style={{ color: accentColor ? `${accentColor}1A` : undefined }}>
                            {copyLabel || 'نسخة'}
                        </div>
                    </div>
                )}

                {/* Copy Label Badge */}
                {copyLabel && (
                    <div className="absolute top-0 left-0 bg-slate-100 px-6 py-2 print:px-2 print:py-1 rounded-br-2xl border-b-2 border-r-2 border-slate-200 z-20 print:border-[#cbd5e1] print:border-b print:border-r print:rounded-br-lg">
                        <span className="font-extrabold text-sm print:text-[8px] uppercase tracking-widest" style={{ color: accentColor }}>{copyLabel}</span>
                    </div>
                )}

                {/* Header Section */}
                <div className="invoice-header relative z-10 border-b-4 border-slate-900 pb-6 mb-2 flex items-center justify-between gap-8 print:pb-2 print:mb-0 print:border-b-2 print:gap-4">
                    {/* Brand Info */}
                    <div className="flex items-center gap-6 print:gap-3">
                        {storeLogoUrl && (
                            <div className="bg-white p-2 rounded-xl border border-slate-100 shadow-sm print:border-none print:shadow-none print:p-0">
                                <img src={storeLogoUrl} alt="Logo" className="h-32 print:h-12 w-auto object-contain" />
                            </div>
                        )}
                        <div className="flex flex-col justify-center">
                            <h1 className="brand-name text-4xl print:text-xl font-black text-slate-900 tracking-tight leading-tight">{systemName}</h1>
                            <div className="text-sm print:text-[8px] font-bold text-slate-500 mt-1 print:mt-0 uppercase tracking-[0.2em]" dir="ltr">{systemKey}</div>

                            <div className="mt-4 flex flex-col gap-1.5 text-sm print:text-[9px] text-slate-600 font-medium print:mt-1 print:gap-0.5">
                                {showBranchName && (
                                    <div className="flex items-center gap-2 print:gap-1">
                                        <span className="text-slate-400 print:hidden">🏢</span>
                                        <span className="font-bold text-slate-800">الفرع:</span>
                                        <span>{branchName}</span>
                                    </div>
                                )}
                                {storeAddress && (
                                    <div className="flex items-center gap-2 print:gap-1">
                                        <span className="text-slate-400 print:hidden">📍</span>
                                        <span className="font-bold text-slate-800">العنوان:</span>
                                        <span>{storeAddress}</span>
                                    </div>
                                )}
                                {storeContactNumber && (
                                    <div className="flex items-center gap-2 print:gap-1">
                                        <span className="text-slate-400 print:hidden">📞</span>
                                        <span className="font-bold text-slate-800">الهاتف:</span>
                                        <span dir="ltr" className="font-mono">{storeContactNumber}</span>
                                    </div>
                                )}
                                {vatNumber && (
                                    <div className="flex items-center gap-2 mt-1 print:mt-0 print:gap-1">
                                        <span className="text-slate-400 print:hidden">🔢</span>
                                        <span className="font-bold text-slate-800">الرقم الضريبي:</span>
                                        <span dir="ltr" className="font-mono font-bold text-slate-900 bg-slate-100 px-2 py-0.5 rounded print:bg-transparent print:px-0 print:py-0">
                                            {vatNumber}
                                        </span>
                                    </div>
                                )}
                            </div>
                        </div>
                    </div>

                    {/* Invoice Title & Meta */}
                    <div className="text-left rtl:text-left flex flex-col items-end">
                        <h2 className="invoice-title text-5xl print:text-2xl font-black text-slate-900 uppercase tracking-tighter">فاتورة</h2>
                        <div className="text-slate-500 text-sm print:text-[8px] font-extrabold tracking-[0.3em] mt-2 print:mt-0.5 uppercase bg-slate-100 px-3 py-1 print:px-0 print:py-0 border border-slate-200 rounded print:bg-transparent print:border-none">فاتورة ضريبية</div>

                        <div className="mt-8 flex gap-6 mt-auto border-t-2 border-slate-100 pt-4 print:mt-2 print:pt-1 print:gap-3 print:border-t">
                            <div className="flex flex-col items-end">
                                <span className="text-[11px] print:text-[7px] font-bold text-slate-400 uppercase tracking-widest mb-1 print:mb-0">تاريخ الإصدار</span>
                                <span className="text-xl print:text-[10px] font-bold font-mono text-slate-700" dir="ltr">{new Date(invoiceDate).toLocaleDateString('en-GB')}</span>
                            </div>
                            <div className="w-px bg-slate-200"></div>
                            <div className="flex flex-col items-end">
                                <span className="text-[11px] print:text-[7px] font-bold text-slate-400 uppercase tracking-widest mb-1 print:mb-0">رقم الفاتورة</span>
                                <span className="text-2xl print:text-xs font-black font-mono text-slate-900" dir="ltr">#{invoiceOrder.invoiceNumber || invoiceOrder.id.slice(-8).toUpperCase()}</span>
                            </div>
                        </div>
                    </div>
                </div>

                {/* Info Grid */}
                <div className="invoice-meta grid grid-cols-12 gap-6 relative z-10 print:gap-2">
                    {/* Bill To */}
                    <div className="col-span-12 md:col-span-5 meta-card bg-slate-50 rounded-2xl p-6 border border-slate-200 shadow-sm relative overflow-hidden print:shadow-none print:rounded-md print:p-2">
                        <div className="absolute top-0 right-0 w-1.5 print:w-1 h-full bg-slate-800"></div>
                        <div className="flex items-center gap-2 mb-4 border-b border-slate-200 pb-2 print:mb-1 print:pb-1">
                            <span className="text-sm print:text-[9px] font-black text-slate-800 uppercase tracking-widest">إلى السادة / العميل</span>
                        </div>
                        <div className="space-y-2 print:space-y-0.5 relative z-10">
                            <div className="text-2xl print:text-xs font-black text-slate-900">{invoiceOrder.customerName}</div>
                            {invoiceOrder.phoneNumber && (
                                <div className="text-base print:text-[10px] text-slate-600 font-mono font-medium flex items-center gap-2 mt-2 print:mt-0" dir="ltr">
                                    <span className="text-slate-400 print:hidden text-lg">📱</span>
                                    {invoiceOrder.phoneNumber}
                                </div>
                            )}
                            {invoiceOrder.address && (
                                <div className="text-sm text-slate-600 mt-2 flex items-start gap-2 leading-relaxed print:text-[9px] print:mt-0 print:leading-tight">
                                    <span className="text-slate-400 mt-0.5 print:hidden text-lg">📍</span>
                                    {invoiceOrder.address}
                                </div>
                            )}
                        </div>
                    </div>

                    {/* Details */}
                    <div className="col-span-12 md:col-span-7 meta-card bg-white rounded-2xl p-6 border border-slate-200 shadow-sm print:shadow-none print:rounded-md print:p-2">
                        <div className="flex items-center gap-2 mb-4 border-b-2 border-slate-100 pb-2 print:mb-1 print:pb-1">
                            <span className="text-sm print:text-[9px] font-black text-slate-800 uppercase tracking-widest">تفاصيل الطلب والدفع</span>
                        </div>
                        <div className="grid grid-cols-2 md:grid-cols-3 gap-y-6 gap-x-6 print:gap-y-1 print:gap-x-2 text-sm print:text-[9px]">
                            <div className="flex flex-col bg-slate-50 p-3 rounded-xl border border-slate-100 print:bg-transparent print:border-none print:p-0">
                                <span className="block text-[11px] print:text-[7px] text-slate-500 font-bold uppercase tracking-wider mb-1.5 print:mb-0.5">طريقة الدفع</span>
                                <span className="font-black text-slate-900 text-base print:text-[10px]">{getPaymentMethodName(invoiceOrder.paymentMethod)}</span>
                            </div>
                            <div className="flex flex-col bg-slate-50 p-3 rounded-xl border border-slate-100 print:bg-transparent print:border-none print:p-0">
                                <span className="block text-[11px] print:text-[7px] text-slate-500 font-bold uppercase tracking-wider mb-1.5 print:mb-0.5">شروط الدفع</span>
                                <span className="font-black text-slate-900 text-base print:text-[10px]">{invoiceTermsLabel}</span>
                            </div>
                            {invoiceTerms === 'credit' && invoiceDueDate && (
                                <div className="flex flex-col bg-slate-50 p-3 rounded-xl border border-slate-100 print:bg-transparent print:border-none print:p-0">
                                    <span className="block text-[11px] print:text-[7px] text-slate-500 font-bold uppercase tracking-wider mb-1.5 print:mb-0.5">تاريخ الاستحقاق</span>
                                    <span className="font-bold text-slate-800 font-mono text-base print:text-[10px]" dir="ltr">{new Date(invoiceDueDate).toLocaleDateString('en-GB')}</span>
                                </div>
                            )}
                            {costCenterLabel && (
                                <div className="flex flex-col bg-slate-50 p-3 rounded-xl border border-slate-100 print:bg-transparent print:border-none print:p-0">
                                    <span className="block text-[11px] print:text-[7px] text-slate-500 font-bold uppercase tracking-wider mb-1.5 print:mb-0.5">مركز التكلفة</span>
                                    <span className="font-bold text-slate-800 text-sm print:text-[10px]">{costCenterLabel}</span>
                                </div>
                            )}
                            {invoiceOrder.orderSource && (
                                <div className="flex flex-col bg-slate-50 p-3 rounded-xl border border-slate-100 print:bg-transparent print:border-none print:p-0">
                                    <span className="block text-[11px] print:text-[7px] text-slate-500 font-bold uppercase tracking-wider mb-1.5 print:mb-0.5">مصدر الطلب</span>
                                    <span className="font-bold text-slate-800 text-sm print:text-[10px]">{invoiceOrder.orderSource === 'in_store' ? 'داخل المتجر' : 'أونلاين'}</span>
                                </div>
                            )}
                            {invoiceOrder.deliveryZoneId && (
                                <div className="flex flex-col bg-slate-50 p-3 rounded-xl border border-slate-100 print:bg-transparent print:border-none print:p-0 md:col-span-2">
                                    <span className="block text-[11px] print:text-[7px] text-slate-500 font-bold uppercase tracking-wider mb-1.5 print:mb-0.5">منطقة التوصيل</span>
                                    <span className="font-bold text-slate-800 text-sm print:text-[10px]">{(deliveryZone?.name?.[lang] || deliveryZone?.name?.ar || deliveryZone?.name?.en) || invoiceOrder.deliveryZoneId}</span>
                                </div>
                            )}
                        </div>
                    </div>
                </div>

                {/* Items Table */}
                <div className="invoice-items relative z-10 overflow-hidden rounded-2xl border-2 border-slate-200 shadow-sm print:border-[#cbd5e1] print:rounded-lg print:border">
                    <table className="w-full text-right border-collapse">
                        <thead>
                            <tr className="bg-slate-900 text-white print:bg-[#0f172a]">
                                <th className="py-4 px-4 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest text-slate-300 w-16 print:w-8 text-center">م</th>
                                <th className="py-4 px-4 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest w-32 print:w-16">الرمز</th>
                                <th className="py-4 px-4 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest">الصنف البيان</th>
                                <th className="py-4 px-4 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest text-center w-36 print:w-20">المستودع</th>
                                <th className="py-4 px-4 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest text-center w-24 print:w-12">الوحدة</th>
                                <th className="py-4 px-4 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest text-center w-24 print:w-10">الكمية</th>
                                <th className="py-4 px-4 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest text-left w-36 print:w-20">{`السعر (${invoiceCurrencyLabel})`}</th>
                                <th className="py-4 px-6 print:py-1 print:px-1 text-[11px] print:text-[8px] font-black uppercase tracking-widest text-left w-40 print:w-24">{`الإجمالي (${invoiceCurrencyLabel})`}</th>
                            </tr>
                        </thead>
                        <tbody className="text-slate-800 text-sm print:text-[10px] bg-white">
                            {invoiceOrder.items.map((item: CartItem, idx: number) => {
                                const itemNo = getItemNumber(item);
                                const pricing = computeInvoiceLine(item, invoicePricingMode);
                                const soldUnitLabel = getSoldUnitLabelAr(item, pricing as any);
                                const soldQtyText = getSoldQuantityTextAr(item, pricing as any);
                                const factor = pricing.factor;
                                const soldUnitPrice = pricing.displayUnitPrice;
                                const lineTotal = pricing.lineTotal;
                                const baseUnitLabel = (() => {
                                    if (pricing.isWeightBased) return soldUnitLabel;
                                    const unitTypeLabel = getUnitLabel((item as any)?.unitType, 'ar');
                                    return unitTypeLabel ? safeUomLabelAr(unitTypeLabel) : 'قطعة';
                                })();

                                return (
                                    <tr key={item.cartItemId} className={`border-b border-slate-100 last:border-0 hover:bg-slate-50 transition-colors`}>
                                        <td className="py-4 px-6 print:py-1 print:px-1 font-mono text-slate-400 text-center text-xs print:text-[8px]">{idx + 1}</td>
                                        <td className="py-4 px-6 print:py-1 print:px-1 font-mono text-slate-700 text-xs print:text-[8px]" dir="ltr">{itemNo}</td>
                                        <td className="py-4 px-6 print:py-1 print:px-1">
                                            <div className="font-bold text-slate-900 text-base print:text-[9px] print:leading-tight">{item.name?.[lang] || item.name?.ar || item.name?.en || item.id}</div>
                                            {!isDense && pricing.addonsArray.length > 0 && (
                                                <div className="flex flex-wrap gap-1 text-xs print:text-[8px] text-slate-500 mt-1.5 print:mt-0.5">
                                                    {pricing.addonsArray.map(({ addon, quantity }: any) => (
                                                        <span key={addon.id} className="bg-slate-50 px-1.5 py-0.5 rounded text-slate-700 border border-slate-200 print:bg-transparent print:border-0 print:px-0 print:py-0 print:rounded-none">
                                                            + {addon.name?.[lang] || addon.name?.ar} {quantity > 1 ? `(${quantity})` : ''}
                                                        </span>
                                                    ))}
                                                </div>
                                            )}
                                            {item.notes && item.notes.trim().length > 0 && (
                                                <div className="mt-1 text-xs text-slate-600 print:text-[8px] print:mt-0.5 whitespace-pre-wrap leading-relaxed">
                                                    {item.notes.trim()}
                                                </div>
                                            )}
                                        </td>
                                        <td className="py-4 px-6 print:py-1 print:px-1 text-center">
                                            <span className="font-bold bg-slate-100 px-3 py-1 rounded-full text-slate-800 print:bg-transparent print:px-0 print:py-0 print:rounded-none">{invoiceWarehouseName || '—'}</span>
                                        </td>
                                        <td className="py-4 px-6 print:py-1 print:px-1 text-center">
                                            <span className="font-bold bg-slate-100 px-3 py-1 rounded-full text-slate-800 print:bg-transparent print:px-0 print:py-0 print:rounded-none">{soldUnitLabel}</span>
                                        </td>
                                        <td className="py-4 px-6 print:py-1 print:px-1 text-center">
                                            <span className="font-mono font-bold bg-slate-100 px-3 py-1 rounded-full text-slate-800 print:bg-transparent print:px-0 print:py-0 print:rounded-none" dir="ltr">{soldQtyText}</span>
                                        </td>
                                        <td className="py-4 px-6 print:py-1 print:px-1 text-left pl-6 print:pl-1" dir="ltr">
                                            <div className="font-mono font-bold text-slate-900 print:text-[9px]">{formatMoney(soldUnitPrice)} {invoiceCurrencyLabel}</div>
                                            {!pricing.isWeightBased && factor !== 1 ? (
                                                <div className="text-[11px] print:text-[7px] text-slate-500 mt-1 print:mt-0">
                                                    {`يعادل ${String(factor)} ${baseUnitLabel}`}
                                                </div>
                                            ) : null}
                                        </td>
                                        <td className="py-4 px-6 print:py-1 print:px-1 text-left font-mono font-bold text-slate-900 pl-8 print:pl-1 text-base print:text-[9px]" dir="ltr">
                                            <div>{formatMoney(lineTotal)} {invoiceCurrencyLabel}</div>
                                        </td>
                                    </tr>
                                );
                            })}
                        </tbody>
                    </table>
                </div>

                {/* Footer Section: Totals, QR, Signatures */}
                <div className="flex flex-col lg:flex-row print:flex-row justify-between items-start gap-8 print:gap-2 mt-2 mb-4 print:mb-0 print:mt-1 relative z-10 print:break-inside-avoid">

                    {/* Left Side: QR & Terms */}
                    <div className="flex flex-col gap-6 w-full lg:flex-1 print:flex-1 print:gap-2">
                        {invoiceTerms === 'credit' ? (
                            <div className="border-2 border-slate-200 rounded-2xl p-6 bg-slate-50 print:bg-transparent print:border-[#cbd5e1] print:rounded-md print:p-2 print:border">
                                <div className="text-sm print:text-[8px] font-bold text-slate-800 leading-relaxed print:leading-normal">
                                    أنا الموقع أدناه أقر باستلام البضاعة المذكورة أعلاه كاملة وسليمة وبحالة جيدة،
                                    وأتعهد بسداد قيمة هذه الفاتورة وفقًا لشروط الدفع المتفق عليها.
                                </div>
                                <div className="mt-6 grid grid-cols-2 gap-4 print:mt-2">
                                    <div className="border-b-2 border-dashed border-slate-400 pb-2 print:pb-0.5 text-center text-xs print:text-[8px] font-bold text-slate-500">
                                        توقيع المستلم / العميل
                                    </div>
                                    <div className="border-b-2 border-dashed border-slate-400 pb-2 print:pb-0.5 text-center text-xs print:text-[8px] font-bold text-slate-500">
                                        توقيع المسؤول / البائع
                                    </div>
                                </div>
                            </div>
                        ) : (
                            <div className="grid grid-cols-2 gap-8 pt-8 print:pt-2 print:gap-4">
                                <div className="border-b-2 border-dashed border-slate-400 pb-2 print:pb-0.5 text-center text-xs print:text-[8px] font-bold text-slate-500">
                                    المستلم
                                </div>
                                <div className="border-b-2 border-dashed border-slate-400 pb-2 print:pb-0.5 text-center text-xs print:text-[8px] font-bold text-slate-500">
                                    البائع
                                </div>
                            </div>
                        )}

                        <div className="flex items-center gap-4 print:gap-2">
                            {qrUrl && (
                                <div className="qr-section p-2 rounded-xl shadow-sm border border-slate-200 bg-white print:p-1 print:rounded-md print:shadow-none">
                                    <img src={qrUrl} alt="ZATCA QR" className="w-16 h-16 object-contain print:w-10 print:h-10" />
                                </div>
                            )}
                            <div className="text-sm print:text-[8px] text-slate-500 font-medium leading-relaxed print:leading-tight">
                                <div className="font-black text-slate-800 mb-0.5 lg:text-base print:text-[9px] print:mb-0">شكراً لثقتكم بنا.</div>
                                نتطلع دائماً لتقديم الأفضل لكم.
                            </div>
                        </div>
                    </div>

                    {/* Right Side: Totals & Balances */}
                    <div className="w-full lg:w-[450px] print:w-[40%] shrink-0 flex flex-col gap-3 print:gap-1">
                        {/* Main Totals Box */}
                        <div className="totals-box bg-slate-900 text-white rounded-3xl p-8 shadow-xl print:shadow-none print:rounded-lg print:p-2 print:border-2 print:border-slate-800">
                            <div className="flex justify-between items-center text-slate-300 font-bold mb-4 print:mb-1">
                                <span className="text-base print:text-[9px]">المجموع الفرعي</span>
                                <span className="font-mono text-lg print:text-[10px] text-white" dir="ltr">
                                    {formatMoney(Number(invoiceOrder.subtotal) || 0)} {invoiceCurrencyLabel}
                                </span>
                            </div>

                            {(invoiceOrder.discountAmount || 0) > 0 && (
                                <div className="flex justify-between items-center text-emerald-400 font-bold mb-4 print:mb-1">
                                    <span className="text-base print:text-[9px]">الخصم</span>
                                    <span className="font-mono text-lg print:text-[10px]" dir="ltr">
                                        - {formatMoney(Number(invoiceOrder.discountAmount) || 0)} {invoiceCurrencyLabel}
                                    </span>
                                </div>
                            )}

                            <div className="flex justify-between items-center text-slate-300 font-bold mb-6 print:mb-1">
                                <span className="text-base print:text-[9px]">ضريبة القيمة المضافة ({Number((invoiceOrder as any).taxRate || 0)}%)</span>
                                <span className="font-mono text-lg print:text-[10px] text-white" dir="ltr">
                                    {formatMoney(taxAmount)} {invoiceCurrencyLabel}
                                </span>
                            </div>

                            <div className="h-0.5 bg-slate-700 w-full mb-6 relative print:mb-1 print:bg-slate-300">
                                <div className="absolute -left-2 top-1/2 -translate-y-1/2 w-4 h-4 bg-white rounded-full print:hidden"></div>
                                <div className="absolute -right-2 top-1/2 -translate-y-1/2 w-4 h-4 bg-white rounded-full print:hidden"></div>
                            </div>

                            <div className="flex justify-between items-center pt-2 print:pt-0">
                                <span className="font-black text-2xl print:text-[11px] text-white print:text-slate-900">الإجمالي</span>
                                <span className="font-black font-mono text-4xl print:text-[12px] tracking-tight text-white print:text-slate-900" dir="ltr">
                                    {formatMoney(Number(invoiceOrder.total) || 0)} {invoiceCurrencyLabel}
                                </span>
                            </div>
                        </div>

                        {/* Credit Summary Box */}
                        {invoiceTerms === 'credit' && creditSummary ? (
                            <div className="credit-summary-box bg-slate-50 border-2 border-slate-200 rounded-3xl p-6 shadow-sm print:shadow-none print:rounded-md print:p-2 print:border">
                                <div className="flex justify-between items-center text-slate-600 mb-3 print:mb-0.5">
                                    <span className="font-extrabold text-sm print:text-[8px]">الرصيد السابق للعميل</span>
                                    <span className="font-mono font-bold text-slate-800 text-base print:text-[9px]" dir="ltr">
                                        {fmtByCode(creditSummary.previousBalance, creditSummary.currencyCode)} {currencyLabelAr(creditSummary.currencyCode)}
                                    </span>
                                </div>
                                <div className="flex justify-between items-center text-slate-600 mb-4 print:mb-1">
                                    <span className="font-extrabold text-sm print:text-[8px]">قيمة الفاتورة الحالية</span>
                                    <span className="font-mono font-bold text-slate-800 text-base print:text-[9px]" dir="ltr">
                                        {fmtByCode(creditSummary.invoiceAmount, creditSummary.currencyCode)} {currencyLabelAr(creditSummary.currencyCode)}
                                    </span>
                                </div>
                                <div className="h-px bg-slate-300 w-full mb-4 print:mb-1"></div>
                                <div className="flex justify-between items-center text-slate-900 bg-white p-3 rounded-xl border border-slate-200 print:bg-transparent print:border-none print:p-0">
                                    <span className="font-black text-lg print:text-[10px]">الرصيد النهائي المستحق</span>
                                    <span className="font-mono font-black text-2xl print:text-[11px] text-rose-600 print:text-slate-900" dir="ltr">
                                        {fmtByCode(creditSummary.newBalance, creditSummary.currencyCode)} {currencyLabelAr(creditSummary.currencyCode)}
                                    </span>
                                </div>
                            </div>
                        ) : null}
                    </div>
                </div>

                {/* Print Meta */}
                <div className="flex justify-between items-center mt-8 pt-4 border-t border-slate-200 text-[10px] print:text-[7px] text-slate-400 font-mono print:mt-2 print:pt-1">
                    <span dir="ltr">{`SYS-REF: ${invoiceOrder.id.slice(0, 16)}`}</span>
                    <span>{printedBy ? `طبع بواسطة: ${printedBy}` : ' '}</span>
                    <span dir="ltr">{new Date().toLocaleString('en-GB')}</span>
                </div>
            </div>
        </div>
    );
});

export const TriplicateInvoice = forwardRef<HTMLDivElement, InvoiceProps>((props, ref) => {
    return (
        <div ref={ref}>
            {/* Original / Customer Copy - Blue/Slate */}
            <div className="print:break-after-page">
                <Invoice
                    {...props}
                    copyLabel="نسخة العميل"
                    accentColor="#1e293b"
                    id="invoice-copy-1"
                />
            </div>

            {/* Warehouse Copy - Red/Orange */}
            <div className="print:break-after-page">
                <Invoice
                    {...props}
                    copyLabel="نسخة المستودع"
                    accentColor="#c2410c" // Orange-700
                    id="invoice-copy-2"
                />
            </div>

            {/* Finance/Box Copy - Green/Emerald */}
            <Invoice
                {...props}
                copyLabel="نسخة الصندوق"
                accentColor="#047857" // Emerald-700
                id="invoice-copy-3"
            />
        </div>
    );
});

export default Invoice;
