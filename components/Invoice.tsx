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
                    * { box-sizing: border-box; }

                    .invoice-container { 
                        width: 100% !important; 
                        padding: 15mm 20mm !important;
                        display: flex !important;
                        flex-direction: column !important;
                        font-size: 8px !important;
                        font-family: 'Tajawal', 'Cairo', sans-serif !important;
                        color: #111827 !important;
                        line-height: 1.5 !important;
                        position: relative !important;
                        min-height: 296mm !important;
                    }

                    /* ═══ THE CERTIFICATE FRAME (ULTRA LUXURY) ═══ */
                    .invoice-container::before {
                        content: '';
                        position: absolute !important;
                        top: 6mm; bottom: 6mm; left: 6mm; right: 6mm;
                        border: 0.5pt solid #C5A059 !important;
                        pointer-events: none !important;
                        z-index: 50 !important;
                    }
                    .invoice-container::after {
                        content: '';
                        position: absolute !important;
                        top: 7mm; bottom: 7mm; left: 7mm; right: 7mm;
                        border: 0.25pt solid #E5E7EB !important;
                        pointer-events: none !important;
                        z-index: 50 !important;
                    }

                    /* ═══ Typography ═══ */
                    .text-gold { color: #C5A059 !important; }
                    .text-charcoal { color: #111827 !important; }
                    .font-thin-label { font-weight: 300 !important; font-size: 6px !important; color: #6B7280 !important; }
                    .font-bold-value { font-weight: 700 !important; font-size: 8px !important; color: #111827 !important; }

                    /* ═══ HEADER ═══ */
                    .luxury-header {
                        display: flex !important;
                        justify-content: space-between !important;
                        align-items: flex-end !important;
                        border-bottom: 0.5pt solid #111827 !important;
                        padding-bottom: 8px !important;
                        margin-bottom: 12px !important;
                    }
                    .brand-name { font-size: 20px !important; font-weight: 800 !important; letter-spacing: -0.2px !important; line-height: 1.1 !important; color: #111827 !important; }
                    .invoice-title { font-size: 24px !important; font-weight: 300 !important; letter-spacing: 4px !important; color: #C5A059 !important; line-height: 1 !important; margin-bottom: 2px !important; }
                    
                    /* ═══ INFO GRID ═══ */
                    .info-grid {
                        display: flex !important;
                        justify-content: space-between !important;
                        margin-bottom: 12px !important;
                        gap: 15px !important;
                    }
                    .info-section {
                        border-right: 1.5pt solid #C5A059 !important;
                        padding-right: 8px !important;
                        flex: 1 !important;
                    }
                    .info-row {
                        display: flex !important;
                        margin-bottom: 2px !important;
                        align-items: baseline !important;
                    }
                    .info-label {
                        width: 50px !important;
                        color: #6B7280 !important;
                        font-size: 5.5px !important;
                        text-transform: uppercase !important;
                        letter-spacing: 0.5px !important;
                    }
                    .info-val {
                        font-weight: 600 !important;
                        font-size: 7px !important;
                        color: #111827 !important;
                    }

                    /* ═══ TABLE ═══ */
                    .luxury-table {
                        width: 100% !important;
                        border-collapse: collapse !important;
                        margin-bottom: 15px !important;
                    }
                    .luxury-table th {
                        border-top: 0.5pt solid #111827 !important;
                        border-bottom: 0.5pt solid #111827 !important;
                        padding: 4px 4px !important;
                        font-weight: 500 !important;
                        font-size: 6px !important;
                        color: #4B5563 !important;
                        text-transform: uppercase !important;
                        letter-spacing: 0.5px !important;
                    }
                    .luxury-table td {
                        padding: 4px 4px !important;
                        font-size: 7px !important;
                        font-weight: 500 !important;
                        border-bottom: 0.5pt dashed #E5E7EB !important;
                        color: #111827 !important;
                    }
                    .luxury-table tr:hover td { background-color: transparent !important; }
                    .luxury-table tr:last-child td {
                        border-bottom: 0.5pt solid #111827 !important;
                    }

                    /* ═══ TOTALS ═══ */
                    .totals-wrapper {
                        display: flex !important;
                        justify-content: space-between !important;
                        align-items: flex-start !important;
                        page-break-inside: avoid !important;
                    }
                    .luxury-totals {
                        width: 55% !important;
                    }
                    .total-row {
                        display: flex !important;
                        justify-content: space-between !important;
                        padding: 3px 0 !important;
                    }
                    .grand-total-row {
                        border-top: 0.5pt solid #111827 !important;
                        border-bottom: 1.5pt double #111827 !important;
                        padding: 4px 0 !important;
                        margin-top: 3px !important;
                    }
                    .grand-total-label { font-size: 9px !important; font-weight: 400 !important; color: #111827 !important; letter-spacing: 1px !important; }
                    .grand-total-value { font-size: 13px !important; font-weight: 800 !important; color: #C5A059 !important; font-family: monospace !important; }

                    /* ═══ FOOTER ═══ */
                    .luxury-footer {
                        margin-top: auto !important;
                        text-align: center !important;
                        font-size: 5px !important;
                        color: #9CA3AF !important;
                        border-top: 0.5pt solid #E5E7EB !important;
                        padding-top: 5px !important;
                        page-break-inside: avoid !important;
                    }

                    .print-hide-subtext { display: none !important; }
                }
            `} </style>

            <div className="invoice-container w-full mx-auto p-12 bg-white flex flex-col text-slate-900 print:p-0" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }} id={id}>

                {/* Watermark for Copy */}
                {(isCopy || copyLabel) && (
                    <div className="pointer-events-none absolute inset-0 flex items-center justify-center overflow-hidden z-0">
                        <div className="text-gray-100 font-bold text-[10rem] print:font-light print:text-[5rem] -rotate-45 select-none opacity-40 print:opacity-[0.03]" style={{ color: accentColor ? accentColor + "1A" : undefined, letterSpacing: "0.2em" }}>
                            {copyLabel || "نسخة"}
                        </div>
                    </div>
                )}

                {/* ▬▬▬ HEADER ▬▬▬ */}
                <div className="luxury-header relative z-10 flex flex-col md:flex-row justify-between items-center md:items-end gap-6 pb-6 mb-8 border-b border-slate-900 print:pb-0 print:mb-0 print:border-none print:flex-row">
                    <div className="flex items-center gap-6 print:gap-3">
                        {storeLogoUrl && (
                            <div className="bg-white p-2 print:p-0">
                                <img src={storeLogoUrl} alt="Logo" className="h-24 print:h-12 w-auto object-contain print:grayscale" />
                            </div>
                        )}
                        <div className="flex flex-col justify-center">
                            <h1 className="brand-name">
                                {systemName}
                                {showBranchName && <span className="text-sm font-normal text-slate-500 mr-2 print:text-[8px] font-sans">({branchName})</span>}
                            </h1>
                            {systemKey && <div className="text-sm print:text-[5px] text-slate-500 uppercase tracking-[0.3em] mt-1 print:mt-0" dir="ltr">{systemKey}</div>}
                            <div className="mt-2 print:mt-1 flex gap-2 text-sm print:text-[5px] text-slate-500">
                                {vatNumber && <span dir="ltr" className="bg-slate-50 print:bg-transparent px-2 py-0.5 rounded print:p-0">VAT: {vatNumber}</span>}
                                {storeContactNumber && <span dir="ltr" className="bg-slate-50 print:bg-transparent px-2 py-0.5 rounded print:p-0">TEL: {storeContactNumber}</span>}
                            </div>
                        </div>
                    </div>

                    <div className="text-center md:text-left rtl:text-left flex flex-col items-center md:items-end flex-shrink-0">
                        <h2 className="invoice-title tracking-widest uppercase">فاتورة</h2>
                        <div className="font-bold tracking-[0.3em] uppercase print:text-[5px] text-slate-400">فاتورة ضريبية TAX INVOICE</div>
                    </div>
                </div>

                {/* ▬▬▬ INFO SECTION ▬▬▬ */}
                <div className="info-grid relative z-10 grid grid-cols-1 md:grid-cols-2 gap-8 mb-8 print:flex print:gap-4 print:mb-4">

                    {/* Customer Info */}
                    <div className="info-section">
                        <div className="text-xs print:text-[5px] text-slate-400 uppercase tracking-widest mb-4 print:mb-1 font-bold">بيانات العميل Bill To</div>
                        <div className="info-row">
                            <span className="info-label">الاسم Name</span>
                            <span className="info-val">{invoiceOrder.customerName}</span>
                        </div>
                        {(invoiceOrder.address || storeAddress) && (
                            <div className="info-row">
                                <span className="info-label">العنوان Addr</span>
                                <span className="info-val">{invoiceOrder.address || storeAddress}</span>
                            </div>
                        )}
                        {invoiceOrder.phoneNumber && (
                            <div className="info-row">
                                <span className="info-label">الهاتف Tel</span>
                                <span className="info-val font-mono" dir="ltr">{invoiceOrder.phoneNumber}</span>
                            </div>
                        )}
                        {deliveryZone && (
                            <div className="info-row">
                                <span className="info-label">منطقة Zone</span>
                                <span className="info-val">{deliveryZone.name?.[lang] || deliveryZone.name?.ar}</span>
                            </div>
                        )}
                    </div>

                    {/* Invoice Meta */}
                    <div className="info-section">
                        <div className="text-xs print:text-[5px] text-slate-400 uppercase tracking-widest mb-4 print:mb-1 font-bold">تفاصيل الفاتورة Details</div>
                        <div className="info-row">
                            <span className="info-label">رقم Invoice</span>
                            <span className="info-val font-mono" dir="ltr">#{invoiceOrder.invoiceNumber || invoiceOrder.id.slice(-8).toUpperCase()}</span>
                        </div>
                        <div className="info-row">
                            <span className="info-label">تاريخ Date</span>
                            <span className="info-val font-mono" dir="ltr">{new Date(invoiceDate).toLocaleDateString("en-GB")}</span>
                        </div>
                        <div className="info-row">
                            <span className="info-label">الدفع Terms</span>
                            <span className="info-val text-gold">{getPaymentMethodName(invoiceOrder.paymentMethod)} - {invoiceTermsLabel}</span>
                        </div>
                        {invoiceDueDate && invoiceTerms === "credit" && (
                            <div className="info-row">
                                <span className="info-label">استحقاق Due</span>
                                <span className="info-val font-mono text-rose-800" dir="ltr">{new Date(invoiceDueDate).toLocaleDateString("en-GB")}</span>
                            </div>
                        )}
                        {costCenterLabel && (
                            <div className="info-row">
                                <span className="info-label">مركز Cost C.</span>
                                <span className="info-val">{costCenterLabel}</span>
                            </div>
                        )}
                        {invoiceWarehouseName && (
                            <div className="info-row">
                                <span className="info-label">مستودع Whse</span>
                                <span className="info-val">{invoiceWarehouseName}</span>
                            </div>
                        )}
                    </div>
                </div>

                {/* ▬▬▬ TABLE ▬▬▬ */}
                <div className="relative z-10 w-full overflow-hidden mb-8 print:mb-4">
                    <table className="luxury-table text-right print:w-full">
                        <thead>
                            <tr>
                                <th className="text-center w-12 print:w-6">م</th>
                                <th className="text-center w-24 print:w-16">الرمز Item</th>
                                <th className="text-right">البيان Description</th>
                                <th className="text-center">الوحدة UOM</th>
                                <th className="text-center">الكمية Qty</th>
                                <th className="text-center">السعر Unit Price</th>
                                <th className="text-center">الإجمالي Total</th>
                            </tr>
                        </thead>
                        <tbody>
                            {invoiceOrder.items.map((item: CartItem, index: number) => {
                                const pricing = computeInvoiceLine(item, invoicePricingMode);
                                const uomLabel = getSoldUnitLabelAr(item, pricing as any);
                                const qtyText = getSoldQuantityTextAr(item, pricing as any);
                                return (
                                    <tr key={index} style={{ pageBreakInside: 'avoid' }}>
                                        <td className="text-center font-mono font-thin-label text-slate-400">{index + 1}</td>
                                        <td className="text-center font-mono font-thin-label text-slate-500">{getItemNumber(item)}</td>
                                        <td className="font-bold-value text-slate-900">
                                            {item.name?.[lang] || item.name?.ar || item.name?.en || item.id}
                                            {pricing.addonsArray.length > 0 && (
                                                <div className="font-thin-label mt-1 print:mt-0 text-[4px]">
                                                    {pricing.addonsArray.map((addon: any, idx: number) => (
                                                        <span key={idx} className="mr-1">
                                                            + {addon.addon.name?.[lang] || addon.addon.name?.ar} ({addon.quantity}x)
                                                        </span>
                                                    ))}
                                                </div>
                                            )}
                                        </td>
                                        <td className="text-center text-slate-600">{uomLabel}</td>
                                        <td className="text-center font-bold-value text-slate-900">{qtyText}</td>
                                        <td className="text-center font-mono text-slate-700">
                                            {fmtByCode(pricing.displayUnitPrice, currencyCode)} <span className="font-thin-label text-[4px]">{currencyCode === 'YER' ? '﷼' : ''}</span>
                                        </td>
                                        <td className="text-center font-mono font-bold-value text-slate-900">
                                            {fmtByCode(pricing.lineTotal, currencyCode)} <span className="font-thin-label text-[4px]">{currencyCode === 'YER' ? '﷼' : ''}</span>
                                        </td>
                                    </tr>
                                )
                            })}
                        </tbody>
                    </table>
                </div>

                {/* ▬▬▬ TOTALS WRAPPER ▬▬▬ */}
                <div className="totals-wrapper relative z-10 grid grid-cols-1 md:grid-cols-2 gap-12 print:flex print:gap-4 print:mb-2">

                    {/* Left side / Footer Info (QR + Signature) */}
                    <div className="flex-1 space-y-8 print:space-y-4 pt-4 print:pt-0">
                        {qrUrl && (
                            <div className="flex gap-4 items-center">
                                <img src={qrUrl} alt="QR Code" className="w-24 h-24 print:w-16 print:h-16 object-contain grayscale opacity-90" />
                            </div>
                        )}
                        <div className="pt-4 border-t border-slate-200 print:border-[0.5pt] print:pt-2 w-48 print:w-24 mt-8 print:mt-4">
                            <div className="text-xs print:text-[5px] text-slate-400 font-bold uppercase tracking-widest text-center">التوقيع Signature</div>
                        </div>
                    </div>

                    {/* Right side / Totals Math */}
                    <div className="luxury-totals">
                        <div className="total-row">
                            <span className="font-thin-label uppercase">المجموع الفرعي Subtotal</span>
                            <span className="font-mono font-bold-value flex gap-2">
                                {fmtByCode((Number(invoiceOrder.subtotal) || 0) + (Number(invoiceOrder.discountAmount) || 0), currencyCode)}
                                <span className="font-thin-label">{invoiceCurrencyLabel}</span>
                            </span>
                        </div>
                        {Number(invoiceOrder.discountAmount) > 0 && (
                            <div className="total-row text-rose-600">
                                <span className="font-thin-label text-rose-500 uppercase">الخصم Discount</span>
                                <span className="font-mono font-bold flex gap-2">
                                    -{fmtByCode(Number(invoiceOrder.discountAmount) || 0, currencyCode)}
                                    <span className="font-thin-label text-rose-300">{invoiceCurrencyLabel}</span>
                                </span>
                            </div>
                        )}
                        {Number(invoiceOrder.deliveryFee) > 0 && (
                            <div className="total-row">
                                <span className="font-thin-label uppercase">التوصيل Delivery</span>
                                <span className="font-mono font-bold-value flex gap-2">
                                    {fmtByCode(invoiceOrder.deliveryFee, currencyCode)}
                                    <span className="font-thin-label">{invoiceCurrencyLabel}</span>
                                </span>
                            </div>
                        )}
                        <div className="total-row pb-2 print:pb-1 mb-1 print:mb-0.5 border-b border-dashed border-slate-200 print:border-[0.5pt]">
                            <span className="font-thin-label uppercase">ض.ق.م VAT ({(Number((invoiceOrder as any).taxRate) || 0)}%)</span>
                            <span className="font-mono font-bold-value flex gap-2">
                                {formatMoney(taxAmount)}
                                <span className="font-thin-label">{invoiceCurrencyLabel}</span>
                            </span>
                        </div>

                        <div className="grand-total-row flex justify-between items-baseline mb-4 print:mb-2">
                            <span className="grand-total-label uppercase tracking-widest">الإجمالي Total</span>
                            <span className="grand-total-value font-mono flex gap-2 items-baseline">
                                {fmtByCode(invoiceOrder.total, currencyCode)}
                                <span className="font-thin-label text-gold font-sans">{invoiceCurrencyLabel}</span>
                            </span>
                        </div>

                        {/* Credit Summary (if applicable) */}
                        {(creditSummary || (invoiceTerms === 'credit' && invoiceOrder.paymentBreakdown)) && (
                            <div className="mt-4 pt-2 print:border-[0.5pt] print:border-t-0 print:border-r-0 print:border-l-0 print:border-slate-800">
                                <div className="text-xs print:text-[5px] text-gold font-bold uppercase tracking-widest mb-2 print:mb-1">كشف الحساب Account</div>
                                {creditSummary ? (
                                    <>
                                        <div className="total-row">
                                            <span className="font-thin-label">رصيد سابق Prev</span>
                                            <span className="font-mono font-bold-value text-slate-700 flex gap-1">
                                                {formatMoney(Number(creditSummary.previousBalance || 0))} <span className="font-thin-label">{currencyLabelAr(creditSummary.currencyCode)}</span>
                                            </span>
                                        </div>
                                        <div className="total-row">
                                            <span className="font-bold-value">رصيد نهائي Balance</span>
                                            <span className="font-mono font-black text-slate-900 flex gap-1 print:text-[6px]">
                                                {formatMoney(Number(creditSummary.newBalance))} <span className="font-thin-label">{currencyLabelAr(creditSummary.currencyCode)}</span>
                                            </span>
                                        </div>
                                    </>
                                ) : (
                                    <>
                                        <div className="total-row">
                                            <span className="font-thin-label">مدفوع Paid</span>
                                            <span className="font-mono font-bold-value text-emerald-600 flex gap-1">
                                                {formatMoney((invoiceOrder.paymentBreakdown?.find((p: any) => p.method === 'cash')?.amount ?? 0) + (invoiceOrder.paymentBreakdown?.find((p: any) => p.method === 'bank')?.amount ?? 0))}
                                            </span>
                                        </div>
                                        <div className="total-row">
                                            <span className="font-bold-value">متبقي Due</span>
                                            <span className="font-mono font-black text-rose-600 flex gap-1 print:text-[6px]">
                                                {formatMoney(invoiceOrder.paymentBreakdown?.find((p: any) => p.method === 'ar')?.amount ?? 0)}
                                            </span>
                                        </div>
                                    </>
                                )}
                            </div>
                        )}
                    </div>
                </div>

                {/* ▬▬▬ FOOTER ▬▬▬ */}
                <div className="luxury-footer w-full font-mono mt-auto relative z-10">
                    <div className="flex justify-center gap-6 print:gap-4 mb-2 print:mb-1">
                        <span>{new Date().toLocaleString('en-GB')}</span>
                        <span>طبع بواسطة: {printedBy}</span>
                        <span>REF: {invoiceOrder.id.slice(0, 16).toUpperCase()}</span>
                    </div>
                    <div className="text-xs print:text-[4px] text-slate-400 font-sans tracking-widest text-[#C5A059] text-center">
                        شكراً لثقتكم بنا — THANK YOU FOR YOUR BUSINESS
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
