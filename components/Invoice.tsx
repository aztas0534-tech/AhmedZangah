import { forwardRef, useEffect, useMemo, useState } from 'react';
import { Order, AppSettings, CartItem } from '../types';
import { useDeliveryZones } from '../contexts/DeliveryZoneContext';
import { computeCartItemPricing } from '../utils/orderUtils';
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

    const getSoldUnitLabelAr = (item: CartItem, pricing: ReturnType<typeof computeCartItemPricing>) => {
        if (pricing.isWeightBased) return safeUomLabelAr(String(pricing.unitType || 'kg'));
        const uomCode = String((item as any)?.uomCode || '').trim();
        if (uomCode) return safeUomLabelAr(uomCode);
        const baseUnit = String((item as any)?.baseUnit || (item as any)?.base_unit || '').trim();
        if (baseUnit) return safeUomLabelAr(baseUnit);
        if (pricing.unitType) return safeUomLabelAr(String(pricing.unitType));
        const unitTypeLabel = getUnitLabel((item as any)?.unitType, 'ar');
        return unitTypeLabel ? safeUomLabelAr(unitTypeLabel) : 'وحدة';
    };

    const getSoldQuantityTextAr = (item: CartItem, pricing: ReturnType<typeof computeCartItemPricing>) => {
        if (pricing.isWeightBased) return String(pricing.quantity);
        return String(item.quantity);
    };

    const qrValue = useMemo(() => {
        if (!vatNumber) return '';
        const total = (Number(invoiceOrder.total) || 0).toFixed(2);
        const vatTotal = taxAmount.toFixed(2);
        return generateZatcaTLV(systemName || systemKey || '—', vatNumber, issueIso, total, vatTotal);
    }, [issueIso, invoiceOrder.total, systemKey, systemName, taxAmount, vatNumber]);

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
                    body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; }
                    .invoice-container { 
                        width: 100% !important; 
                        max-width: none !important; 
                        margin: 0 !important; 
                        padding: 4mm !important;
                        box-sizing: border-box;
                    }
                    .invoice-container.invoice-dense {
                        padding: 3mm !important;
                        gap: 10px !important;
                    }
                    .invoice-container.invoice-dense .invoice-header {
                        padding-bottom: 6px !important;
                        margin-bottom: 10px !important;
                    }
                    .invoice-container.invoice-dense .invoice-meta {
                        gap: 10px !important;
                        margin-bottom: 10px !important;
                    }
                    .invoice-container.invoice-dense .meta-card {
                        padding: 8px !important;
                    }
                    .invoice-container.invoice-dense .brand-name {
                        font-size: 20px !important;
                        line-height: 1.1 !important;
                    }
                    .invoice-container.invoice-dense .invoice-title {
                        font-size: 28px !important;
                        line-height: 1.1 !important;
                    }
                    .invoice-container.invoice-dense .invoice-items table {
                        font-size: 10px !important;
                        line-height: 1.15 !important;
                    }
                    .invoice-container.invoice-dense .invoice-items th {
                        padding-top: 4px !important;
                        padding-bottom: 4px !important;
                    }
                    .invoice-container.invoice-dense .invoice-items td {
                        padding-top: 4px !important;
                        padding-bottom: 4px !important;
                    }
                }
            `}</style>
            <div className={`invoice-container w-full mx-auto p-12 print:p-2 flex flex-col gap-8 print:gap-4 h-full ${isDense ? 'invoice-dense' : ''}`} style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }} id={id}>
            {/* Watermark for Copy */}
            {(isCopy || copyLabel) && (
                <div className="pointer-events-none absolute inset-0 flex items-center justify-center overflow-hidden z-0">
                    <div className="text-gray-100 font-black text-[10rem] -rotate-45 select-none opacity-60" style={{ color: accentColor ? `${accentColor}20` : undefined }}>
                        {copyLabel || 'نسخة'}
                    </div>
                </div>
            )}

            {/* Copy Label Badge */}
            {copyLabel && (
                <div className="absolute top-0 left-0 bg-slate-100 px-4 py-2 rounded-br-xl border-b border-r border-slate-200 z-20">
                    <span className="font-bold text-xs uppercase tracking-wider" style={{ color: accentColor }}>{copyLabel}</span>
                </div>
            )}

            {/* Header Section */}
            <div className="invoice-header relative z-10 border-b-2 border-slate-200 pb-6 mb-8 print:pb-2 print:mb-4">
                <div className="flex items-start justify-between gap-8 print:gap-4">
                    {/* Brand Info */}
                    <div className="flex-1">
                        <div className="flex items-start gap-5">
                            {storeLogoUrl && (
                                <img src={storeLogoUrl} alt="Logo" className="h-28 print:h-20 w-auto object-contain drop-shadow-sm" />
                            )}
                            <div>
                                <h1 className="brand-name text-4xl print:text-2xl font-black text-slate-900 tracking-tight">{systemName}</h1>
                                <div className="text-sm print:text-xs font-bold text-slate-500 mt-1 uppercase tracking-widest" dir="ltr">{systemKey}</div>
                                <div className="mt-4 print:mt-2 space-y-1.5 text-sm print:text-xs text-slate-600">
                                    {showBranchName && (
                                        <div className="flex items-center gap-2">
                                            <span className="w-4 h-4 flex items-center justify-center bg-slate-100 rounded text-slate-500 text-[10px] print:hidden">🏢</span>
                                            <span className="font-bold text-slate-800">الفرع:</span>
                                            <span>{branchName}</span>
                                        </div>
                                    )}
                                    {storeAddress && (
                                        <div className="flex items-center gap-2">
                                            <span className="w-4 h-4 flex items-center justify-center bg-slate-100 rounded text-slate-500 text-[10px] print:hidden">📍</span>
                                            <span className="font-bold text-slate-800">العنوان:</span>
                                            <span>{storeAddress}</span>
                                        </div>
                                    )}
                                    {storeContactNumber && (
                                        <div className="flex items-center gap-2">
                                            <span className="w-4 h-4 flex items-center justify-center bg-slate-100 rounded text-slate-500 text-[10px] print:hidden">📞</span>
                                            <span className="font-bold text-slate-800">الهاتف:</span>
                                            <span dir="ltr">{storeContactNumber}</span>
                                        </div>
                                    )}
                                    {vatNumber && (
                                        <div className="flex items-center gap-2">
                                            <span className="w-4 h-4 flex items-center justify-center bg-slate-100 rounded text-slate-500 text-[10px] print:hidden">🔢</span>
                                            <span className="font-bold text-slate-800">الرقم الضريبي:</span>
                                            <span dir="ltr" className="font-mono bg-slate-50 px-1 rounded">{vatNumber}</span>
                                        </div>
                                    )}
                                </div>
                            </div>
                        </div>
                    </div>

                    {/* Invoice Title & Meta */}
                    <div className="text-left rtl:text-left">
                        <h2 className="invoice-title text-5xl print:text-3xl font-black text-slate-900 uppercase tracking-tighter">فاتورة</h2>
                        <div className="text-slate-400 text-sm print:text-xs font-bold tracking-[0.4em] mt-1 uppercase">فاتورة ضريبية</div>

                        <div className="mt-8 print:mt-4 flex flex-col gap-3 print:gap-2 items-end">
                            <div className="inline-flex flex-col items-end border-r-4 border-slate-800 pr-4">
                                <span className="text-[10px] font-bold text-slate-400 uppercase tracking-wider">رقم الفاتورة</span>
                                <span className="text-2xl print:text-lg font-black font-mono text-slate-800" dir="ltr">{invoiceOrder.invoiceNumber || invoiceOrder.id.slice(-8).toUpperCase()}</span>
                            </div>
                            <div className="inline-flex flex-col items-end border-r-4 border-slate-300 pr-4 mt-1">
                                <span className="text-[10px] font-bold text-slate-400 uppercase tracking-wider">التاريخ</span>
                                <span className="text-lg print:text-sm font-bold font-mono text-slate-700" dir="ltr">{new Date(invoiceDate).toLocaleDateString('en-GB')}</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            {/* Info Grid */}
            <div className="invoice-meta grid grid-cols-2 gap-12 print:gap-4 mb-10 print:mb-4 relative z-10">
                {/* Bill To */}
                <div className="meta-card bg-slate-50 rounded-xl p-6 print:p-2 border border-slate-200 shadow-sm relative overflow-hidden group">
                    <div className="absolute top-0 right-0 w-1 h-full bg-slate-800"></div>
                    <div className="flex items-center gap-2 mb-4 print:mb-2 border-b border-slate-200 pb-2 print:pb-1">
                        <span className="text-sm print:text-xs font-black text-slate-800 uppercase tracking-wider">بيانات العميل</span>
                    </div>
                    <div className="space-y-1.5 relative z-10">
                        <div className="text-xl print:text-base font-bold text-slate-900">{invoiceOrder.customerName}</div>
                        {invoiceOrder.phoneNumber && (
                            <div className="text-sm print:text-xs text-slate-600 font-mono flex items-center gap-2" dir="ltr">
                                <span className="text-slate-400 print:hidden">📱</span>
                                {invoiceOrder.phoneNumber}
                            </div>
                        )}
                        {invoiceOrder.address && (
                            <div className="text-sm print:text-xs text-slate-600 mt-1 flex items-start gap-2">
                                <span className="text-slate-400 mt-1 print:hidden">📍</span>
                                {invoiceOrder.address}
                            </div>
                        )}
                    </div>
                </div>

                {/* Details */}
                <div className="meta-card bg-white rounded-xl p-6 print:p-2 border border-slate-200 shadow-sm relative">
                    <div className="flex items-center gap-2 mb-4 print:mb-2 border-b border-slate-100 pb-2">
                        <span className="text-sm print:text-xs font-black text-slate-800 tracking-wider">تفاصيل الفاتورة</span>
                    </div>
                    <div className="grid grid-cols-2 gap-y-5 print:gap-y-2 gap-x-8 print:gap-x-4 text-sm print:text-xs">
                        <div>
                            <span className="block text-[10px] text-slate-400 font-bold uppercase mb-1">طريقة الدفع</span>
                            <span className="font-bold text-slate-800 bg-slate-100 px-2 py-1 rounded text-xs">{getPaymentMethodName(invoiceOrder.paymentMethod)}</span>
                        </div>
                        <div>
                            <span className="block text-[10px] text-slate-400 font-bold uppercase mb-1">شروط الدفع</span>
                            <span className="font-bold text-slate-800">{invoiceTermsLabel}</span>
                        </div>
                        {costCenterLabel ? (
                            <div className="col-span-2">
                                <span className="block text-[10px] text-slate-400 font-bold uppercase mb-1">مركز التكلفة</span>
                                <span className="font-bold text-slate-800">{costCenterLabel}</span>
                            </div>
                        ) : null}
                        {invoiceTerms === 'credit' && invoiceDueDate && (
                            <div>
                                <span className="block text-[10px] text-slate-400 font-bold uppercase mb-1">تاريخ الاستحقاق</span>
                                <span className="font-bold text-slate-600 font-mono bg-slate-100 px-2 py-1 rounded text-xs" dir="ltr">{new Date(invoiceDueDate).toLocaleDateString('en-GB')}</span>
                            </div>
                        )}
                        {invoiceOrder.orderSource && (
                            <div>
                                <span className="block text-[10px] text-slate-400 font-bold uppercase mb-1">المصدر</span>
                                <span className="font-bold text-slate-800">{invoiceOrder.orderSource === 'in_store' ? 'داخل المتجر' : 'أونلاين'}</span>
                            </div>
                        )}
                        {invoiceOrder.deliveryZoneId && (
                            <div className="col-span-2">
                                <span className="block text-[10px] text-slate-400 font-bold uppercase mb-1">منطقة التوصيل</span>
                                <span className="font-bold text-slate-800">{(deliveryZone?.name?.[lang] || deliveryZone?.name?.ar || deliveryZone?.name?.en) || invoiceOrder.deliveryZoneId}</span>
                            </div>
                        )}
                        {invoiceTerms === 'credit' && creditSummary ? (
                            <div className="col-span-2">
                                <div className="mt-2 border border-slate-200 rounded-xl p-3 bg-slate-50">
                                    <div className="grid grid-cols-3 gap-3 text-center">
                                        <div>
                                            <div className="text-[10px] text-slate-500 font-bold">الرصيد السابق</div>
                                            <div className="font-mono font-black text-slate-900" dir="ltr">
                                                {fmtByCode(creditSummary.previousBalance, creditSummary.currencyCode)} {creditSummary.currencyCode}
                                            </div>
                                        </div>
                                        <div>
                                            <div className="text-[10px] text-slate-500 font-bold">قيمة الفاتورة</div>
                                            <div className="font-mono font-black text-slate-900" dir="ltr">
                                                {fmtByCode(creditSummary.invoiceAmount, creditSummary.currencyCode)} {creditSummary.currencyCode}
                                            </div>
                                        </div>
                                        <div>
                                            <div className="text-[10px] text-slate-500 font-bold">إجمالي الرصيد</div>
                                            <div className="font-mono font-black text-slate-900" dir="ltr">
                                                {fmtByCode(creditSummary.newBalance, creditSummary.currencyCode)} {creditSummary.currencyCode}
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        ) : null}
                    </div>
                </div>
            </div>

            {/* Items Table */}
            <div className="invoice-items mb-10 print:mb-3 relative z-10 overflow-hidden rounded-xl border border-slate-200 shadow-sm">
                <table className="w-full text-right border-collapse">
                    <thead>
                        <tr className="bg-slate-900 text-white">
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest text-slate-400 w-16 text-center">#</th>
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest w-32">رقم الصنف</th>
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest">اسم الصنف</th>
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest text-center w-40">المخزن</th>
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest text-center w-28">الوحدة</th>
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest text-center w-28">الكمية</th>
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest text-left pl-6 w-40">{`سعر الوحدة (${invoiceCurrencyLabel})`}</th>
                            <th className="py-4 px-6 print:py-1 print:px-1 text-[10px] font-black uppercase tracking-widest text-left pl-8 w-44">{`الإجمالي (${invoiceCurrencyLabel})`}</th>
                        </tr>
                    </thead>
                    <tbody className="text-slate-800 text-sm print:text-[10px] bg-white">
                        {invoiceOrder.items.map((item: CartItem, idx: number) => {
                            const pricing = computeCartItemPricing(item);
                            const itemNo = getItemNumber(item);
                            const soldUnitLabel = getSoldUnitLabelAr(item, pricing);
                            const soldQtyText = getSoldQuantityTextAr(item, pricing);
                            const baseUnitPrice = pricing.unitPrice;
                            const factor = pricing.isWeightBased ? 1 : (Number((item as any)?.uomQtyInBase || 1) || 1);
                            const soldUnitPrice = pricing.isWeightBased ? baseUnitPrice : baseUnitPrice * factor;
                            const lineTotal = pricing.lineTotal;
                            const baseUnitLabel = (() => {
                                if (pricing.isWeightBased) return soldUnitLabel;
                                const unitTypeLabel = getUnitLabel((item as any)?.unitType, 'ar');
                                return unitTypeLabel ? safeUomLabelAr(unitTypeLabel) : 'قطعة';
                            })();

                            return (
                                <tr key={item.cartItemId} className={`border-b border-slate-100 last:border-0 hover:bg-slate-50 transition-colors`}>
                                    <td className="py-4 px-6 print:py-1 print:px-1 font-mono text-slate-400 text-center text-xs">{idx + 1}</td>
                                    <td className="py-4 px-6 print:py-1 print:px-1 font-mono text-slate-700 text-xs" dir="ltr">{itemNo}</td>
                                    <td className="py-4 px-6 print:py-1 print:px-1">
                                        <div className="font-bold text-slate-900 text-base print:text-[11px] print:leading-tight">{item.name?.[lang] || item.name?.ar || item.name?.en || item.id}</div>
                                        {!isDense && pricing.addonsArray.length > 0 && (
                                            <div className="flex flex-wrap gap-1 text-xs print:text-[9px] text-slate-500 mt-1.5 print:mt-0.5">
                                                {pricing.addonsArray.map(({ addon, quantity }) => (
                                                    <span key={addon.id} className="bg-slate-50 px-1.5 py-0.5 rounded text-slate-700 border border-slate-200 print:bg-transparent print:border-0 print:px-0 print:py-0 print:rounded-none">
                                                        + {addon.name?.[lang] || addon.name?.ar} {quantity > 1 ? `(${quantity})` : ''}
                                                    </span>
                                                ))}
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
                                    <td className="py-4 px-6 print:py-1 print:px-1 text-left pl-6" dir="ltr">
                                        <div className="font-mono font-bold text-slate-900 print:text-[10px]">{formatMoney(soldUnitPrice)} {invoiceCurrencyLabel}</div>
                                        {!pricing.isWeightBased && factor !== 1 ? (
                                            <div className="text-[11px] print:text-[9px] text-slate-500">
                                                {`يعادل ${String(factor)} ${baseUnitLabel}`}
                                            </div>
                                        ) : null}
                                    </td>
                                    <td className="py-4 px-6 print:py-1 print:px-1 text-left font-mono font-bold text-slate-900 pl-8 text-base print:text-[11px]" dir="ltr">
                                        <div>{formatMoney(lineTotal)} {invoiceCurrencyLabel}</div>
                                    </td>
                                </tr>
                            );
                        })}
                    </tbody>
                </table>
            </div>

            {/* Footer Section: QR & Totals */}
            <div className="flex flex-col md:flex-row gap-12 print:gap-6 items-start relative z-10">
                {/* Left: QR & Notes */}
                <div className="flex-1">
                    {qrUrl && (
                        <div className="flex items-start gap-5 print:gap-3 bg-slate-50 border border-slate-200 p-5 print:p-2 rounded-2xl shadow-sm w-fit">
                            <div className="bg-white p-2 rounded-xl shadow-sm border border-slate-100">
                                <img src={qrUrl} alt="ZATCA QR" className="w-28 h-28 print:w-16 print:h-16 object-contain" />
                            </div>
                            <div className="space-y-2 pt-2">
                                <div className="text-xs print:text-[10px] font-black text-slate-900 uppercase tracking-wider">التحقق الضريبي</div>
                                <div className="text-[10px] text-slate-500 max-w-[140px] leading-relaxed print:hidden">
                                    هذه الفاتورة متوافقة مع متطلبات هيئة الزكاة والضريبة والجمارك (ZATCA). امسح الرمز للتحقق.
                                </div>
                            </div>
                        </div>
                    )}

                    {/* Payment Breakdown if exists */}
                    {!isDense && (invoiceOrder as any).paymentBreakdown && (invoiceOrder as any).paymentBreakdown?.methods && (invoiceOrder as any).paymentBreakdown.methods.length > 0 && (
                        <div className="mt-8 text-sm border-t border-slate-200 pt-6 max-w-xs">
                            <div className="font-bold text-slate-900 mb-3 flex items-center gap-2">
                                <span className="w-1.5 h-1.5 bg-green-500 rounded-full"></span>
                                تفاصيل السداد:
                            </div>
                            <div className="space-y-2 text-slate-600 bg-slate-50 p-3 rounded-lg border border-slate-100">
                                {(invoiceOrder as any).paymentBreakdown.methods.map((m: any, idx: number) => (
                                    <div key={idx} className="flex justify-between items-center text-xs">
                                        <span>{getPaymentMethodName(m.method)}</span>
                                        <span className="font-mono font-bold text-slate-800" dir="ltr">{Number(m.amount).toFixed(2)}</span>
                                    </div>
                                ))}
                            </div>
                        </div>
                    )}
                </div>

                {/* Right: Totals */}
                <div className="w-full md:w-[420px]">
                    <div className="bg-slate-900 text-white rounded-2xl p-8 print:p-4 shadow-lg space-y-4 print:space-y-2 relative overflow-hidden">

                        <div className="flex justify-between items-center text-slate-300 relative z-10">
                            <span className="font-medium text-sm print:text-xs">المجموع الفرعي</span>
                            <span className="font-mono font-bold text-white" dir="ltr">
                                {formatMoney(Number(invoiceOrder.subtotal) || 0)} {invoiceCurrencyLabel}
                            </span>
                        </div>

                        {(invoiceOrder.discountAmount || 0) > 0 && (
                            <div className="flex justify-between items-center text-emerald-400 relative z-10">
                                <span className="font-medium text-sm print:text-xs">الخصم</span>
                                <span className="font-mono font-bold" dir="ltr">
                                    - {formatMoney(Number(invoiceOrder.discountAmount) || 0)} {invoiceCurrencyLabel}
                                </span>
                            </div>
                        )}

                        <div className="flex justify-between items-center text-slate-300 relative z-10">
                            <span className="font-medium text-sm print:text-xs">ضريبة القيمة المضافة ({Number((invoiceOrder as any).taxRate || 0)}%)</span>
                            <span className="font-mono font-bold text-white" dir="ltr">
                                {formatMoney(taxAmount)} {invoiceCurrencyLabel}
                            </span>
                        </div>

                        <div className="h-px bg-slate-700 my-2 relative z-10"></div>

                        <div className="flex justify-between items-center relative z-10">
                            <span className="font-black text-xl print:text-base">الإجمالي</span>
                            <span className="font-black font-mono text-3xl print:text-xl tracking-tight text-white" dir="ltr">
                                {formatMoney(Number(invoiceOrder.total) || 0)} {invoiceCurrencyLabel}
                            </span>
                        </div>
                    </div>
                </div>
            </div>

            {/* Footer Bottom */}
            <div className="mt-auto pt-16 print:pt-4">
                {invoiceTerms === 'credit' ? (
                    <div className="mb-8 print:mb-3 border border-slate-200 rounded-2xl p-5 print:p-3 bg-white">
                        <div className="text-sm print:text-xs text-slate-700 leading-relaxed">
                            أنا الموقع أدناه أقر باستلام البضاعة كاملة وسليمة، وأتعهد بسداد قيمة الفاتورة وفقًا لشروطها.
                        </div>
                        <div className="mt-4 print:mt-2 grid grid-cols-2 gap-6">
                            <div className="h-16 print:h-10 border-2 border-dashed border-slate-200 rounded-xl bg-slate-50/50 flex items-end justify-center pb-2">
                                <span className="text-[10px] text-slate-400">توقيع العميل</span>
                            </div>
                            <div className="h-16 print:h-10 border-2 border-dashed border-slate-200 rounded-xl bg-slate-50/50 flex items-end justify-center pb-2">
                                <span className="text-[10px] text-slate-400">توقيع المسؤول</span>
                            </div>
                        </div>
                    </div>
                ) : null}
                {!isDense && (
                    <div className="grid grid-cols-3 gap-12 print:gap-4 text-center text-sm print:text-xs text-slate-500 border-t border-slate-200 pt-8 print:pt-2">
                    <div className="space-y-3">
                        <div className="font-bold text-slate-900 text-xs uppercase tracking-wider">المستلم</div>
                        <div className="h-20 print:h-12 border-2 border-dashed border-slate-200 rounded-xl bg-slate-50/50 flex items-end justify-center pb-2">
                            <span className="text-[10px] text-slate-400">التوقيع</span>
                        </div>
                    </div>
                    <div className="space-y-2 pt-6 flex flex-col items-center justify-center">
                        <div className="w-8 h-1 bg-slate-800 rounded-full mb-2"></div>
                        <div className="font-black text-slate-900 text-lg print:text-base">{systemName}</div>
                        <div className="text-[10px] font-medium tracking-wide text-slate-400">شكراً لتعاملكم معنا</div>
                    </div>
                    <div className="space-y-3">
                        <div className="font-bold text-slate-900 text-xs uppercase tracking-wider">البائع</div>
                        <div className="h-20 print:h-12 border-2 border-dashed border-slate-200 rounded-xl bg-slate-50/50 flex items-end justify-center pb-2">
                            <span className="text-[10px] text-slate-400">الختم</span>
                        </div>
                    </div>
                    </div>
                )}
                {/* Print Meta */}
                <div className={`flex justify-between items-center mt-10 print:mt-3 pt-4 print:pt-2 border-t border-slate-100 text-[9px] text-slate-400 font-mono ${isDense ? 'mt-4 print:mt-2' : ''}`}>
                    <span dir="ltr">{`مرجع النظام: ${invoiceOrder.id}`}</span>
                    <span>{printedBy ? `طبع بواسطة: ${printedBy}` : ' '}</span>
                    <span dir="ltr">{`تاريخ الطباعة: ${new Date().toISOString()}`}</span>
                    <span>صفحة 1 من 1</span>
                </div>
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
