import { numberToArabicWords } from '../utils/tafqeet';
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
        <div ref={ref} className="bg-white relative font-sans print:w-full print:max-w-none print:m-0 print:p-0 overflow-hidden" dir="rtl">
            <style>{`
                @media print {
                    @page { size: A5 portrait; margin: 0; }
                    body { -webkit-print-color-adjust: exact; print-color-adjust: exact; margin: 0; padding: 0; background: white; }
                    * { box-sizing: border-box; }

                    .invoice-container { 
                        width: 100% !important; 
                        padding: 3mm 3mm 2mm 3mm !important;
                        display: flex !important;
                        flex-direction: column !important;
                        font-family: 'Tajawal', 'Cairo', 'Dubai', sans-serif !important;
                        color: #0F172A !important;
                        line-height: 1.2 !important;
                        position: relative !important;
                        background-color: #FAFAFA !important;
                    }

                    /* ═══ WATERMARK ═══ */
                    .luxury-watermark {
                        position: absolute !important;
                        top: 50% !important;
                        left: 50% !important;
                        transform: translate(-50%, -50%) rotate(-30deg) !important;
                        font-size: 12rem !important;
                        font-weight: 900 !important;
                        color: #D4AF37 !important;
                        opacity: 0.03 !important;
                        white-space: nowrap !important;
                        pointer-events: none !important;
                        z-index: 1 !important;
                        letter-spacing: -2px !important;
                    }

                    /* ═══ THE CERTIFICATE FRAME ═══ */
                    .invoice-container::before {
                        content: '';
                        position: absolute !important;
                        top: 1mm; bottom: 1mm; left: 1mm; right: 1mm;
                        border: 1.5pt solid #1E3A8A !important;
                        pointer-events: none !important;
                        z-index: 50 !important;
                    }
                    .invoice-container::after {
                        content: '';
                        position: absolute !important;
                        top: 2mm; bottom: 2mm; left: 2mm; right: 2mm;
                        border: 0.5pt solid #D4AF37 !important;
                        pointer-events: none !important;
                        z-index: 50 !important;
                    }

                    /* ═══ Typography ═══ */
                    .text-gold { color: #1e293b !important; } /* Darkened to slate-800 for better print clarity instead of actual gold */
                    .text-charcoal { color: #000000 !important; }
                    .font-thin-label { font-weight: 800 !important; font-size: 10px !important; color: #111827 !important; text-transform: uppercase !important; letter-spacing: 0.3px !important; }
                    .font-bold-value { font-weight: 900 !important; font-size: 12px !important; color: #000000 !important; }

                    /* ═══ HEADER ═══ */
                    .luxury-header {
                        display: flex !important;
                        justify-content: space-between !important;
                        align-items: center !important;
                        border-bottom: 1.5pt solid #1E3A8A !important;
                        padding-bottom: 2px !important;
                        margin-bottom: 4px !important;
                    }
                    .brand-name { font-size: 18px !important; font-weight: 900 !important; letter-spacing: -0.5px !important; line-height: 1 !important; color: #0F172A !important; margin-bottom: 1px !important; }
                    .invoice-title { font-size: 26px !important; font-weight: 800 !important; letter-spacing: -1px !important; color: #D4AF37 !important; line-height: 0.9 !important; }
                    .title-sub { font-size: 8px !important; font-weight: 800 !important; letter-spacing: 1.5px !important; color: #0F172A !important; text-transform: uppercase !important; border-top: 0.5pt solid #D4AF37 !important; padding-top: 1px !important; margin-top: 1px !important; text-align: center !important; }
                    
                    /* ═══ INFO GRID ═══ */
                    .info-grid {
                        display: flex !important;
                        justify-content: space-between !important;
                        margin-bottom: 3px !important;
                        background: #F3F4F6 !important;
                        border: 0.5pt solid #E5E7EB !important;
                        padding: 2px 5px !important;
                    }
                    .info-group {
                        display: flex !important;
                        flex-direction: column !important;
                        gap: 1px !important;
                    }
                    .info-item {
                        display: flex !important;
                        flex-direction: column !important;
                    }

                    /* ═══ TABLE ═══ */
                    .luxury-table {
                        width: 100% !important;
                        border-collapse: collapse !important;
                        margin-bottom: 3px !important;
                    }
                    .luxury-table thead {
                        display: table-header-group !important;
                    }
                    .luxury-table tfoot {
                        display: table-footer-group !important;
                    }
                    .luxury-table th {
                        background-color: #0F172A !important;
                        color: #FFFFFF !important;
                        padding: 1.5px 2px !important;
                        font-weight: 700 !important;
                        font-size: 10px !important;
                        text-transform: uppercase !important;
                        letter-spacing: 0.3px !important;
                        border: none !important;
                    }
                    .luxury-table td {
                        padding: 1.5px 2px !important;
                        font-size: 11px !important;
                        font-weight: 700 !important;
                        line-height: 1 !important;
                        border-bottom: 0.5pt solid #E5E7EB !important;
                        color: #0F172A !important;
                    }
                    .luxury-table tr {
                        page-break-inside: avoid !important;
                    }
                    .luxury-table tr:nth-child(even) td { background-color: #F9FAFB !important; }
                    .luxury-table tr:last-child td { border-bottom: 1.5pt solid #1E3A8A !important; }

                    /* Identification row that repeats on every page */
                    .invoice-id-row td {
                        background-color: #EFF6FF !important;
                        border-bottom: 1pt solid #1E3A8A !important;
                        padding: 1px 4px !important;
                        font-size: 8px !important;
                        font-weight: 800 !important;
                        color: #1E3A8A !important;
                    }

                    /* Continuation footer */
                    .luxury-table tfoot td {
                        background-color: #F9FAFB !important;
                        border-top: 0.5pt dashed #9CA3AF !important;
                        border-bottom: none !important;
                        padding: 1.5px 4px !important;
                        font-size: 8px !important;
                        color: #9CA3AF !important;
                        text-align: center !important;
                        font-style: italic !important;
                    }

                    /* ═══ TOTALS ═══ */
                    .totals-wrapper {
                        display: flex !important;
                        justify-content: space-between !important;
                        align-items: flex-start !important;
                        page-break-inside: avoid !important;
                    }
                    .qr-section {
                        border: 0.5pt solid #D4AF37 !important;
                        padding: 2px !important;
                        background: white !important;
                    }
                    .luxury-totals {
                        width: 55% !important;
                    }
                    .total-row {
                        display: flex !important;
                        justify-content: space-between !important;
                        padding: 1.5px 3px !important;
                    }
                    .grand-total-row {
                        display: flex !important;
                        justify-content: space-between !important;
                        align-items: center !important;
                        background-color: #0F172A !important;
                        color: white !important;
                        padding: 3px 6px !important;
                        margin-top: 2px !important;
                        border-radius: 2px !important;
                    }
                    .grand-total-label { font-size: 13px !important; font-weight: 800 !important; color: #FFFFFF !important; letter-spacing: 0.5px !important; }
                    .grand-total-value { font-size: 18px !important; font-weight: 900 !important; color: #D4AF37 !important; font-family: monospace !important; }

                    /* ═══ SUMMARY BOXES ═══ */
                    .summary-box {
                        border: 0.5pt solid #E5E7EB !important;
                        background: #F9FAFB !important;
                        padding: 2px !important;
                        margin-top: 2px !important;
                        page-break-inside: avoid !important;
                    }

                    /* ═══ PLEDGE / LEGAL ═══ */
                    .pledge-section {
                        page-break-inside: avoid !important;
                    }
                    .signatures-section {
                        page-break-inside: avoid !important;
                    }

                    /* ═══ FOOTER ═══ */
                    .luxury-footer {
                        margin-top: auto !important;
                        text-align: center !important;
                        font-size: 7px !important;
                        color: #4B5563 !important;
                        padding-top: 2px !important;
                        page-break-inside: avoid !important;
                        display: flex !important;
                        flex-direction: column !important;
                        align-items: center !important;
                        gap: 1px !important;
                    }
                    .footer-line {
                        width: 40px !important;
                        height: 0.5pt !important;
                        background-color: #D4AF37 !important;
                        margin: 1px 0 !important;
                    }

                    .print-hide-subtext { display: none !important; }
                }

                /* Hide print-only elements on screen */
                @media screen {
                    .invoice-id-row { display: none; }
                    .luxury-table tfoot { display: none; }
                }
            `} </style>

            <div className="invoice-container w-full mx-auto p-6 md:p-12 bg-[#FAFAFA] flex flex-col text-blue-950 print:!p-[2mm] print:!m-0 print:!w-full print:!max-w-none" style={{ fontFamily: 'Tajawal, Cairo, sans-serif' }} id={id}>

                <div className="luxury-watermark">{systemName}</div>

                {/* Watermark for Copy */}
                {(isCopy || copyLabel) && (
                    <div className="pointer-events-none absolute inset-0 flex items-center justify-center overflow-hidden z-0">
                        <div className="text-gray-100 font-bold text-[10rem] print:font-black print:text-[8rem] -rotate-45 select-none opacity-40 print:opacity-[0.06]" style={{ color: accentColor ? accentColor + "1A" : undefined, letterSpacing: "0.2em" }}>
                            {copyLabel || "نسخة"}
                        </div>
                    </div>
                )}

                {/* ▬▬▬ HEADER ▬▬▬ */}
                <div className="luxury-header relative z-10 flex flex-col md:flex-row justify-between items-center md:items-end gap-6 pb-6 mb-8 border-b-2 border-slate-900 print:pb-0 print:mb-0 print:border-none print:flex-row">
                    <div className="flex items-center gap-6 print:gap-4">
                        {storeLogoUrl && (
                            <div className="bg-white p-2 print:p-1 mt-2 z-10">
                                <img src={storeLogoUrl} alt="Logo" className="h-24 print:h-20 w-auto object-contain print:grayscale" />
                            </div>
                        )}
                        <div className="flex flex-col justify-center">
                            <h1 className="brand-name">
                                {systemName}
                                {showBranchName && <span className="text-sm font-normal text-slate-500 mr-2 print:text-[10px] font-sans">({branchName})</span>}
                            </h1>
                            {systemKey && <div className="text-sm print:text-[8px] text-slate-500 uppercase tracking-[0.3em] font-mono print:mt-0" dir="ltr">{systemKey}</div>}
                            <div className="mt-2 print:mt-1 flex gap-3 text-sm print:text-[7px] text-slate-700 font-bold">
                                {vatNumber && <span dir="ltr">VAT: <span className="font-mono text-blue-950">{vatNumber}</span></span>}
                                {storeContactNumber && <span dir="ltr">TEL: <span className="font-mono text-blue-950">{storeContactNumber}</span></span>}
                            </div>
                        </div>
                    </div>

                    <div className="text-center md:text-left rtl:text-left flex flex-col items-center flex-shrink-0 z-10">
                        <h2 className="invoice-title">فاتورة</h2>
                        <div className="title-sub">فاتورة ضريبية TAX INVOICE</div>
                        {copyLabel && (
                            <div className="mt-2 text-[12px] print:text-[14px] font-bold text-center border-2 border-[#D4AF37] text-[#D4AF37] bg-[#D4AF371A] px-3 py-1 rounded-md tracking-wider">
                                {copyLabel}
                            </div>
                        )}
                    </div>
                </div>

                {/* ▬▬▬ INFO SECTION (Horizontal Grid) ▬▬▬ */}
                <div className="info-grid relative z-10 mb-8 print:mb-3">
                    <div className="info-group">
                        <div className="info-item mb-2 print:mb-1">
                            <span className="font-thin-label">العميل | Customer</span>
                            <span className="font-bold-value text-gold">{invoiceOrder.customerName}</span>
                        </div>
                        {(invoiceOrder.address || storeAddress) && (
                            <div className="info-item mb-2 print:mb-1">
                                <span className="font-thin-label">العنوان | Address</span>
                                <span className="font-bold-value">{invoiceOrder.address || storeAddress}</span>
                            </div>
                        )}
                        {invoiceOrder.phoneNumber && (
                            <div className="info-item">
                                <span className="font-thin-label">الهاتف | Phone</span>
                                <span className="font-bold-value font-mono" dir="ltr">{invoiceOrder.phoneNumber}</span>
                            </div>
                        )}
                    </div>

                    <div className="info-group border-r border-slate-300 pr-4 print:border-l print:border-r-0 print:border-[#E5E7EB] print:pl-4 print:pr-0">
                        <div className="info-item mb-2 print:mb-1">
                            <span className="font-thin-label">رقم الفاتورة | Invoice No.</span>
                            <span className="font-bold-value font-mono text-charcoal" dir="ltr">#{invoiceOrder.invoiceNumber || invoiceOrder.id.slice(-8).toUpperCase()}</span>
                        </div>
                        <div className="info-item mb-2 print:mb-1">
                            <span className="font-thin-label">التاريخ | Date</span>
                            <span className="font-bold-value font-mono" dir="ltr">{new Date(invoiceDate).toLocaleDateString("en-GB")} {new Date(invoiceDate).toLocaleTimeString("en-GB", { hour: '2-digit', minute: '2-digit' })}</span>
                        </div>
                        <div className="info-item">
                            <span className="font-thin-label">شروط الدفع | Terms</span>
                            <span className="font-bold-value text-charcoal">
                                {getPaymentMethodName(invoiceOrder.paymentMethod)} - {invoiceTermsLabel}
                                {invoiceOrder.orderSource && <span className="text-[5px] text-slate-500 mr-1 opacity-70">({invoiceOrder.orderSource === 'in_store' ? 'متجر' : 'تطبيق'})</span>}
                            </span>
                        </div>
                    </div>

                    <div className="info-group border-r border-slate-300 pr-4 print:border-l print:border-r-0 print:border-[#E5E7EB] print:pl-4 print:pr-0">
                        {invoiceDueDate && invoiceTerms === "credit" && (
                            <div className="info-item mb-2 print:mb-1">
                                <span className="font-thin-label">الاستحقاق | Due Date</span>
                                <span className="font-bold-value font-mono text-rose-700" dir="ltr">{new Date(invoiceDueDate).toLocaleDateString("en-GB")}</span>
                            </div>
                        )}
                        {deliveryZone && (
                            <div className="info-item mb-2 print:mb-1">
                                <span className="font-thin-label">المنطقة | Zone</span>
                                <span className="font-bold-value text-charcoal">{deliveryZone.name?.[lang] || deliveryZone.name?.ar}</span>
                            </div>
                        )}
                        <div className="flex gap-4 print:gap-2">
                            {costCenterLabel && (
                                <div className="info-item">
                                    <span className="font-thin-label">مركز | Cost C.</span>
                                    <span className="font-bold-value">{costCenterLabel}</span>
                                </div>
                            )}
                            {invoiceWarehouseName && (
                                <div className="info-item border-slate-300 pr-4 print:border-r print:border-[#E5E7EB] print:pr-2">
                                    <span className="font-thin-label">مستودع | Whse</span>
                                    <span className="font-bold-value">{invoiceWarehouseName}</span>
                                </div>
                            )}
                        </div>
                    </div>
                </div>

                {/* ▬▬▬ TABLE ▬▬▬ */}
                <div className="relative z-10 w-full mb-8 print:mb-3">
                    <table className="luxury-table text-right print:w-full">
                        <thead>
                            {/* Identification row - repeats on every printed page */}
                            <tr className="invoice-id-row">
                                <td colSpan={4} style={{ textAlign: 'right' }}>
                                    فاتورة رقم: #{invoiceOrder.invoiceNumber || invoiceOrder.id.slice(-8).toUpperCase()} | العميل: {invoiceOrder.customerName}
                                </td>
                                <td colSpan={4} style={{ textAlign: 'left' }} dir="ltr">
                                    {new Date(invoiceDate).toLocaleDateString('en-GB')} {copyLabel ? `| ${copyLabel}` : ''}
                                </td>
                            </tr>
                            <tr>
                                <th className="text-center w-8 print:w-4">م</th>
                                <th className="text-center w-20 print:w-14">الرمز</th>
                                <th className="text-right">البيان DESCRIPTION</th>
                                <th className="text-center">المستودع WHS</th>
                                <th className="text-center">الوحدة UOM</th>
                                <th className="text-center">الكمية QTY</th>
                                <th className="text-center">السعر PRICE</th>
                                <th className="text-center">المجموع TOTAL</th>
                            </tr>
                        </thead>
                        <tfoot>
                            <tr>
                                <td colSpan={8}>يتبع في الصفحة التالية... | Continued on next page</td>
                            </tr>
                        </tfoot>
                        <tbody>
                            {invoiceOrder.items.map((item: CartItem, index: number) => {
                                const pricing = computeInvoiceLine(item, invoicePricingMode);
                                const uomLabel = getSoldUnitLabelAr(item, pricing as any);
                                const qtyText = getSoldQuantityTextAr(item, pricing as any);
                                return (
                                    <tr key={index} style={{ pageBreakInside: 'avoid' }}>
                                        <td className="text-center font-mono font-thin-label text-slate-400">{index + 1}</td>
                                        <td className="text-center font-mono font-thin-label text-charcoal">{getItemNumber(item)}</td>
                                        <td className="font-bold-value text-blue-950">
                                            {item.name?.[lang] || item.name?.ar || item.name?.en || item.id}
                                            {pricing.addonsArray.length > 0 && (
                                                <div className="font-thin-label mt-1 print:mt-0 text-[4px] text-slate-500">
                                                    {pricing.addonsArray.map((addon: any, idx: number) => (
                                                        <span key={idx} className="mr-1">
                                                            + {addon.addon.name?.[lang] || addon.addon.name?.ar} (x{addon.quantity})
                                                        </span>
                                                    ))}
                                                </div>
                                            )}
                                        </td>
                                        <td className="text-center font-bold-value text-slate-600">{invoiceWarehouseName || "-"}</td>
                                        <td className="text-center text-slate-600">{uomLabel}</td>
                                        <td className="text-center font-bold-value text-charcoal">{qtyText}</td>
                                        <td className="text-center font-mono text-charcoal">
                                            {fmtByCode(pricing.displayUnitPrice, currencyCode)}
                                        </td>
                                        <td className="text-center font-mono font-bold-value text-charcoal">
                                            {fmtByCode(pricing.lineTotal, currencyCode)}
                                        </td>
                                    </tr>
                                )
                            })}
                        </tbody>
                    </table>
                </div>

                {/* ▬▬▬ TOTALS WRAPPER ▬▬▬ */}
                <div className="totals-wrapper relative z-10 grid grid-cols-1 md:grid-cols-2 gap-12 print:flex print:gap-4 print:mb-2 w-full">

                    {/* Left side / Footer Info (QR) */}
                    <div className="flex-1 flex flex-col justify-end pt-4 print:pt-0">
                        <div className="flex gap-4 items-end mb-4 print:mb-1 print:gap-3">
                            {qrUrl && (
                                <div className="qr-section">
                                    <img src={qrUrl} alt="QR Code" className="w-24 h-24 print:w-16 print:h-16 object-contain" />
                                </div>
                            )}
                            {/* Official Entity Stamp space */}
                            <div className="flex-1 flex justify-center items-center h-24 print:h-12 border border-slate-200 print:border-[#E5E7EB] border-dashed rounded-sm opacity-50">
                                <div className="font-thin-label text-center text-slate-400">الختم الرسمي<br />OFFICIAL STAMP</div>
                            </div>
                        </div>
                    </div>

                    {/* Right side / Totals Math */}
                    <div className="luxury-totals">
                        <div className="total-row">
                            <span className="font-thin-label">المجموع الفرعي | Subtotal</span>
                            <span className="font-mono font-bold-value flex gap-1 items-center">
                                {fmtByCode((Number(invoiceOrder.subtotal) || 0) + (Number(invoiceOrder.discountAmount) || 0), currencyCode)}
                                <span className="font-thin-label text-charcoal mt-[1px]">{invoiceCurrencyLabel}</span>
                            </span>
                        </div>
                        {Number(invoiceOrder.discountAmount) > 0 && (
                            <div className="total-row">
                                <span className="font-thin-label text-rose-600">الخصم | Discount</span>
                                <span className="font-mono font-bold text-rose-600 flex gap-1 print:text-[7px] items-center">
                                    -{fmtByCode(Number(invoiceOrder.discountAmount) || 0, currencyCode)}
                                    <span className="font-thin-label text-rose-600 mt-[1px]">{invoiceCurrencyLabel}</span>
                                </span>
                            </div>
                        )}
                        {Number(invoiceOrder.deliveryFee) > 0 && (
                            <div className="total-row">
                                <span className="font-thin-label">التوصيل | Delivery</span>
                                <span className="font-mono font-bold-value flex gap-1 items-center">
                                    {fmtByCode(invoiceOrder.deliveryFee, currencyCode)}
                                    <span className="font-thin-label text-charcoal mt-[1px]">{invoiceCurrencyLabel}</span>
                                </span>
                            </div>
                        )}
                        <div className="total-row pb-2 print:pb-1 relative">
                            <span className="font-thin-label">ضريبة ق.م | VAT ({(Number((invoiceOrder as any).taxRate) || 0)}%)</span>
                            <span className="font-mono font-bold-value flex gap-1 items-center">
                                {formatMoney(taxAmount)}
                                <span className="font-thin-label text-charcoal mt-[1px]">{invoiceCurrencyLabel}</span>
                            </span>
                        </div>

                        <div className="grand-total-row">
                            <span className="grand-total-label">الإجمالي | TOTAL</span>
                            <span className="grand-total-value flex gap-2 items-center">
                                {fmtByCode(invoiceOrder.total, currencyCode)}
                                <span className="text-[5px] font-sans text-white uppercase tracking-widest">{invoiceCurrencyLabel}</span>
                            </span>
                        </div>
                        <div className="bg-slate-50 border border-slate-200 print:border-[#E5E7EB] mt-1 p-1 text-center">
                            <span className="font-bold-value text-charcoal print:text-[5.5px]">
                                {numberToArabicWords(Number(invoiceOrder.total), currencyCode, 'هللة / فلس')}
                            </span>
                        </div>

                        {/* Credit Summary (if applicable) */}
                        {(creditSummary || (invoiceTerms === 'credit' && invoiceOrder.paymentBreakdown)) && (
                            <div className="summary-box">
                                <div className="font-thin-label mb-2 print:mb-1 text-gold text-center">كشف الحساب | Account Statement</div>
                                {creditSummary ? (
                                    <>
                                        <div className="total-row">
                                            <span className="font-thin-label">رصيد سابق | Prev</span>
                                            <span className="font-mono font-bold-value text-blue-800 flex gap-1 items-center">
                                                {formatMoney(Number(creditSummary.previousBalance || 0))}
                                                <span className="font-thin-label mt-[1px]">{currencyCode}</span>
                                            </span>
                                        </div>
                                        <div className="total-row border-t border-slate-200 mt-1 pt-1 print:border-[#E5E7EB]">
                                            <span className="font-bold-value text-[6px]">رصيد نهائي | Balance</span>
                                            <span className="font-mono font-black text-blue-950 flex gap-1 print:text-[8px] bg-gold-50 items-center">
                                                {formatMoney(Number(creditSummary.newBalance))}
                                                <span className="font-thin-label text-[4px] mt-[1px]">{currencyCode}</span>
                                            </span>
                                        </div>
                                    </>
                                ) : (
                                    <>
                                        <div className="total-row">
                                            <span className="font-thin-label">مدفوع | Paid</span>
                                            <span className="font-mono font-bold-value text-emerald-600 flex gap-1 items-center">
                                                {formatMoney((invoiceOrder.paymentBreakdown?.find((p: any) => p.method === 'cash')?.amount ?? 0) + (invoiceOrder.paymentBreakdown?.find((p: any) => p.method === 'bank')?.amount ?? 0))}
                                                <span className="font-thin-label mt-[1px]">{currencyCode}</span>
                                            </span>
                                        </div>
                                        <div className="total-row border-t border-slate-200 mt-1 pt-1 print:border-[#E5E7EB]">
                                            <span className="font-bold-value text-[6px] text-rose-700">متبقي | Due</span>
                                            <span className="font-mono font-black text-rose-700 flex gap-1 print:text-[8px] items-center">
                                                {formatMoney(invoiceOrder.paymentBreakdown?.find((p: any) => p.method === 'ar')?.amount ?? 0)}
                                                <span className="font-thin-label text-[4px] mt-[1px]">{currencyCode}</span>
                                            </span>
                                        </div>
                                    </>
                                )}
                            </div>
                        )}
                    </div>
                </div>

                {/* ▬▬▬ LEGAL & SIGNATURES ▬▬▬ */}
                <div className="relative z-10 w-full mt-4 print:mt-1">
                    {/* Pledge for Credit / Unpaid Balance */}
                    {(creditSummary || (invoiceTerms === 'credit' && invoiceOrder.paymentBreakdown)) && (
                        <div className="pledge-section border border-blue-900 print:border-blue-900 p-3 print:p-1.5 mb-6 print:mb-2 bg-white text-center">
                            <p className="text-[8px] print:text-[5.5px] font-bold text-blue-950 leading-relaxed print:leading-snug font-sans text-justify px-2 print:px-1">
                                أنا الموقع أدناه المستلم / <span className="inline-block w-48 print:w-24 border-b-2 border-slate-400 print:border-blue-900 border-dotted"></span> بأنني استلمت البضاعة أعلاه كاملة وسليمة وأتعهد بسداد قيمتها كاملة وغير منقوصة لأمر <span className="font-black text-rose-700">{systemName}</span> إلى تاريخ الاستحقاق الموضح أعلاه وفي حال التأخر عن السداد أكون ملزماً بتسديد مبلغ الفاتورة ومصاريف التأخير حسب ما تقره المؤسسة ولها الحق الكامل بـ الاستيلاء على البضاعة المشتراة منها أو أي بضاعة أخرى أو على أي أموالنا بما يساوي مبلغ الدين والمصاريف.
                            </p>
                            <div className="mt-4 print:mt-2 flex justify-between items-end px-4">
                                <div className="text-center font-bold text-[8px] print:text-[5.5px]">
                                    <span>المستلم: ...............................</span>
                                </div>
                                <div className="text-center font-bold text-[8px] print:text-[5.5px]">
                                    <span>التوقيع: ...............................</span>
                                </div>
                            </div>
                        </div>
                    )}

                    {/* Official Signatures Row */}
                    <div className="signatures-section flex justify-between items-end mt-8 print:mt-3 px-4 print:px-2">
                        <div className="text-center w-32 print:w-16">
                            <div className="border-t border-blue-900 print:border-blue-900 pt-1.5 print:pt-0.5">
                                <span className="font-thin-label block text-blue-950 font-bold">المستلم | Receiver</span>
                            </div>
                        </div>
                        <div className="text-center w-32 print:w-16">
                            <div className="border-t border-blue-900 print:border-blue-900 pt-1.5 print:pt-0.5">
                                <span className="font-thin-label block text-blue-950 font-bold">أمين الصندوق | Cashier</span>
                            </div>
                        </div>
                        <div className="text-center w-32 print:w-16">
                            <div className="border-t border-blue-900 print:border-blue-900 pt-1.5 print:pt-0.5">
                                <span className="font-thin-label block text-blue-950 font-bold">المحاسب | Accountant</span>
                            </div>
                        </div>
                        <div className="text-center w-32 print:w-16">
                            <div className="border-t border-blue-900 print:border-blue-900 pt-1.5 print:pt-0.5">
                                <span className="font-thin-label block text-blue-950 font-bold">المدير | Manager</span>
                            </div>
                        </div>
                    </div>
                </div>

                {/* ▬▬▬ FOOTER ▬▬▬ */}
                <div className="luxury-footer relative z-10 w-full font-mono mt-auto pt-2">
                    <div className="footer-line"></div>
                    <div className="font-bold-value text-gold mb-1 print:mb-0.5 mt-1 font-sans tracking-wide">شكراً لثقتكم بنا — THANK YOU FOR YOUR BUSINESS</div>
                    <div className="flex justify-center gap-4 text-slate-400 font-sans">
                        <span>{new Date().toLocaleString('en-GB')}</span>
                        <span>طبع بواسطة: {printedBy}</span>
                        <span>REF: {invoiceOrder.id.slice(0, 8).toUpperCase()}</span>
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
