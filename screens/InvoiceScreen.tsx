import React, { useEffect, useRef, useState, useMemo } from 'react';
import { useParams, Link, useNavigate, useLocation } from 'react-router-dom';
import { useOrders } from '../contexts/OrderContext';
import { useToast } from '../contexts/ToastContext';
import Invoice, { TriplicateInvoice } from '../components/Invoice';
import { printPdfFromElement, sharePdf } from '../utils/export';
import { buildPdfBrandOptions } from '../utils/branding';
import { BackArrowIcon, ShareIcon, PrinterIcon } from '../components/icons';
import { buildPrintHtml, printContent } from '../utils/printUtils';
import { renderToString } from 'react-dom/server';
import PrintableInvoice, { generateZatcaTLV } from '../components/admin/PrintableInvoice';
import PrintableOrder from '../components/admin/PrintableOrder';
import { Capacitor } from '@capacitor/core';
import PageLoader from '../components/PageLoader';
import { useSettings } from '../contexts/SettingsContext';
import { getBaseCurrencyCode, getSupabaseClient } from '../supabase';
import ConfirmationModal from '../components/admin/ConfirmationModal';
import { useAuth } from '../contexts/AuthContext';
import { useSessionScope } from '../contexts/SessionScopeContext';
import { useWarehouses } from '../contexts/WarehouseContext';
import { useDeliveryZones } from '../contexts/DeliveryZoneContext';
import QRCode from 'qrcode';
import { AZTA_IDENTITY } from '../config/identity';
import CurrencyDualAmount from '../components/common/CurrencyDualAmount';


const InvoiceScreen: React.FC = () => {
    const { orderId } = useParams<{ orderId: string }>();
    const { getOrderById, incrementInvoicePrintCount, loading } = useOrders();
    const { showNotification } = useToast();
    const navigate = useNavigate();
    const location = useLocation();
    const order = getOrderById(orderId || '');
    const invoiceRef = useRef<HTMLDivElement>(null);
    const [isSharing, setIsSharing] = useState(false);
    const [isPrinting, setIsPrinting] = useState(false);
    const [isPrintingA4, setIsPrintingA4] = useState(false);
    const [isPrintingA4Pdf, setIsPrintingA4Pdf] = useState(false);
    const [invoiceAudit, setInvoiceAudit] = useState<any>(null);
    const { settings, language } = useSettings();
    const storeName = (settings.cafeteriaName?.[language] || settings.cafeteriaName?.ar || settings.cafeteriaName?.en || '').trim();
    const safeStoreSlug = storeName.replace(/\s+/g, '-');
    const thermalPaperWidth: '58mm' | '80mm' = settings.posFlags?.thermalPaperWidth === '80mm' ? '80mm' : '58mm';
    const isAdminInvoice = (location.pathname || '').startsWith('/admin/');
    const { user: adminUser } = useAuth();
    const sessionScope = useSessionScope();
    const { getWarehouseById } = useWarehouses();
    const { getDeliveryZoneById } = useDeliveryZones();
    const [costCenterLabel, setCostCenterLabel] = useState<string>('');
    const [creditSummary, setCreditSummary] = useState<{ previousBalance: number; invoiceAmount: number; newBalance: number; currencyCode: string } | null>(null);
    const [selectedTemplate, setSelectedTemplate] = useState<'thermal' | 'a4'>(() => {
        if (adminUser?.role === 'cashier') {
            return settings.defaultInvoiceTemplateByRole?.pos === 'a4' ? 'a4' : 'thermal';
        }
        if (isAdminInvoice) {
            return settings.defaultInvoiceTemplateByRole?.admin === 'thermal' ? 'thermal' : 'a4';
        }
        return 'a4';
    });
    const [previewOpen, setPreviewOpen] = useState(false);
    const [previewKind, setPreviewKind] = useState<'thermal' | 'a4'>('thermal');
    const [previewHtml, setPreviewHtml] = useState<string>('');
    const [previewTitle, setPreviewTitle] = useState<string>('معاينة الطباعة');
    const autoPrintRunKeyRef = useRef<string>('');

    const resolveBranding = () => {
        const fallback = {
            name: storeName,
            address: settings.address || '',
            contactNumber: settings.contactNumber || '',
            logoUrl: settings.logoUrl || '',
        };
        const warehouseId = (order as any)?.warehouseId || sessionScope.scope?.warehouseId || '';
        const wh = warehouseId ? getWarehouseById(String(warehouseId)) : undefined;
        const key = warehouseId ? String(warehouseId) : '';
        const override = key ? settings.branchBranding?.[key] : undefined;
        return {
            name: (override?.name || wh?.name || fallback.name || '').trim(),
            address: (override?.address || wh?.address || wh?.location || fallback.address || '').trim(),
            contactNumber: (override?.contactNumber || wh?.phone || fallback.contactNumber || '').trim(),
            logoUrl: (override?.logoUrl || fallback.logoUrl || '').trim(),
        };
    };

    const isUuidText = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
    const isCreditInvoice = (ord: any): boolean => {
        if (!ord) return false;
        const snap = ord.invoiceSnapshot;
        const terms = String(snap?.invoiceTerms ?? ord.invoiceTerms ?? '').trim().toLowerCase();
        const method = String(snap?.paymentMethod ?? ord.paymentMethod ?? '').trim().toLowerCase();
        return terms === 'credit' || method === 'ar';
    };

    useEffect(() => {
        if (!order?.id) {
            setCostCenterLabel('');
            return;
        }
        const supabase = getSupabaseClient();
        if (!supabase) return;
        let cancelled = false;
        (async () => {
            const branchId = String(sessionScope.scope?.branchId || '').trim();
            if (branchId) {
                try {
                    const { data, error } = await supabase.from('branches').select('name,code').eq('id', branchId).maybeSingle();
                    if (error) throw error;
                    const name = String((data as any)?.name || '').trim();
                    const code = String((data as any)?.code || '').trim();
                    const label = [name, code ? `(${code})` : ''].filter(Boolean).join(' ');
                    if (!cancelled) setCostCenterLabel(label);
                    return;
                } catch {
                }
            }
            const wid = String((order as any)?.warehouseId || sessionScope.scope?.warehouseId || '').trim();
            const w = wid ? getWarehouseById(wid) : null;
            const label = String(w?.name || '').trim();
            if (!cancelled) setCostCenterLabel(label);
        })();
        return () => { cancelled = true; };
    }, [getWarehouseById, order?.id, sessionScope.scope?.branchId, sessionScope.scope?.warehouseId]);

    useEffect(() => {
        if (!order?.id) {
            setCreditSummary(null);
            return;
        }
        if (!isCreditInvoice(order)) {
            setCreditSummary(null);
            return;
        }
        const supabase = getSupabaseClient();
        if (!supabase) return;
        let cancelled = false;
        (async () => {
            const baseCode = String((await getBaseCurrencyCode()) || '').trim().toUpperCase() || 'YER';
            const snap = (order as any).invoiceSnapshot || null;
            const asOf = String(snap?.issuedAt || (order as any).invoiceIssuedAt || (order as any).deliveredAt || (order as any).createdAt || new Date().toISOString());

            let partyId = String((order as any).partyId || '').trim();
            if (!isUuidText(partyId)) {
                try {
                    const { data, error } = await supabase.from('orders').select('party_id').eq('id', order.id).maybeSingle();
                    if (!error) {
                        const pid = String((data as any)?.party_id || '').trim();
                        if (isUuidText(pid)) partyId = pid;
                    }
                } catch {
                }
            }
            if (!isUuidText(partyId)) {
                if (!cancelled) setCreditSummary(null);
                return;
            }

            const fx = Number((snap?.fxRate ?? (order as any)?.fxRate ?? 1) || 1) || 1;
            const orderCurrency = String((snap?.currency ?? (order as any)?.currency ?? '')).trim().toUpperCase();
            const totalForeign = Number(snap?.total ?? (order as any)?.total ?? 0) || 0;
            const computedInvoiceBase = orderCurrency && orderCurrency !== baseCode ? (totalForeign * fx) : totalForeign;
            const statementCurrency = (orderCurrency || baseCode).trim().toUpperCase() || baseCode;
            const invoiceAmountInStatementCurrency = statementCurrency !== baseCode ? totalForeign : computedInvoiceBase;

            const loadStatement = async (endIso: string | null) => {
                const { data, error } = await supabase.rpc('party_ledger_statement_v2', {
                    p_party_id: partyId,
                    p_account_code: '1200',
                    p_currency: statementCurrency || null,
                    p_start: null,
                    p_end: endIso,
                } as any);
                if (error) throw error;
                return Array.isArray(data) ? data : [];
            };

            let rows: any[] = [];
            try {
                rows = await loadStatement(asOf || null);
            } catch {
                try {
                    rows = await loadStatement(null);
                } catch {
                    rows = [];
                }
            }
            if (rows.length === 0) {
                if (!cancelled) setCreditSummary(null);
                return;
            }

            const orderRows = rows.filter((r) => String(r?.source_table || '').trim().toLowerCase() === 'orders' && String(r?.source_id || '').trim() === String(order.id).trim());
            const lastRow = rows[rows.length - 1];
            const orderRow = orderRows.length ? orderRows[orderRows.length - 1] : null;
            const running = Number((orderRow || lastRow)?.running_foreign_balance ?? (orderRow || lastRow)?.running_balance ?? 0) || 0;

            const deriveInvoiceImpact = () => {
                if (orderRow) {
                    const dir = String(orderRow?.direction || '').trim().toLowerCase();
                    const amt = Number(orderRow?.foreign_amount ?? orderRow?.base_amount ?? 0) || 0;
                    const nb = String(orderRow?.account_normal_balance || 'debit').trim().toLowerCase();
                    const signed = nb === 'credit'
                        ? (dir === 'credit' ? 1 : -1) * Math.abs(amt)
                        : (dir === 'debit' ? 1 : -1) * Math.abs(amt);
                    return { signed, amount: Math.abs(amt) };
                }
                return { signed: Math.abs(invoiceAmountInStatementCurrency), amount: Math.abs(invoiceAmountInStatementCurrency) };
            };
            const impact = deriveInvoiceImpact();
            const previous = running - (impact.signed || 0);

            if (!cancelled) {
                setCreditSummary({
                    previousBalance: previous,
                    invoiceAmount: impact.amount || 0,
                    newBalance: running,
                    currencyCode: statementCurrency,
                });
            }
        })();
        return () => { cancelled = true; };
    }, [order?.id]);

    const resolveDeliveryZoneName = (ord: any): string | undefined => {
        if (!ord) return undefined;
        const snap = ord.invoiceSnapshot;
        const orderSource = snap?.orderSource ?? ord.orderSource;
        const zoneId = snap?.deliveryZoneId ?? ord.deliveryZoneId;
        if (!zoneId) return undefined;
        if (orderSource === 'in_store') return language === 'ar' ? 'داخل المحل' : 'In-store';
        const zone = getDeliveryZoneById(zoneId);
        const name = zone?.name?.[language] || zone?.name?.ar || zone?.name?.en || '';
        return name || undefined;
    };

    useEffect(() => {
        if (!order?.id) {
            setInvoiceAudit(null);
            return;
        }
        const supabase = getSupabaseClient();
        if (!supabase) {
            setInvoiceAudit(null);
            return;
        }
        let cancelled = false;
        (async () => {
            try {
                const { data, error } = await supabase.rpc('get_invoice_audit', { p_order_id: order.id });
                if (error) throw error;
                if (!cancelled) setInvoiceAudit(data || null);
            } catch {
                if (!cancelled) setInvoiceAudit(null);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [order?.id]);

    const handleSharePdf = async () => {
        if (!order) return;
        setIsSharing(true);
        const isMobile = Capacitor.isNativePlatform() || /Mobi|Android/i.test(navigator.userAgent);
        let success = false;
        const brand = resolveBranding();
        const brandSettings: any = {
            ...settings,
            cafeteriaName: { ...(settings as any).cafeteriaName, ar: brand.name, en: brand.name },
            logoUrl: brand.logoUrl,
            address: brand.address,
            contactNumber: brand.contactNumber,
        };
        if (isMobile) {
            const containerId = 'thermal-print-area';
            const container = document.createElement('div');
            container.id = containerId;
            container.style.position = 'fixed';
            container.style.top = '-10000px';
            container.style.left = '0';
            container.style.width = '576px';
            container.style.background = '#ffffff';
            const currentCount = typeof order.invoicePrintCount === 'number' ? order.invoicePrintCount : 0;
            const printedBy = (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null;
            const thermalHtml = renderToString(
                <PrintableInvoice
                    order={order}
                    audit={{ ...(invoiceAudit || {}), printedBy }}
                    language="ar"
                    companyName={storeName}
                    companyPhone={settings.contactNumber || ''}
                    companyAddress={settings.address || ''}
                    logoUrl={settings.logoUrl || ''}
                    vatNumber={settings.taxSettings?.taxNumber}
                    deliveryZoneName={resolveDeliveryZoneName(order)}
                    thermal
                    thermalPaperWidth={thermalPaperWidth}
                    isCopy={currentCount > 0}
                    copyNumber={currentCount > 0 ? currentCount + 1 : undefined}
                    costCenterLabel={costCenterLabel || undefined}
                    creditSummary={creditSummary}
                />
            );
            container.innerHTML = thermalHtml;
            document.body.appendChild(container);
            success = await sharePdf(
                containerId,
                `${'فاتورة'} ${order.id.slice(-6).toUpperCase()}`,
                `Invoice-${safeStoreSlug}-${order.id.slice(-6).toUpperCase()}.pdf`,
                { unit: 'px', scale: 1.5, ...buildPdfBrandOptions(brandSettings, `فاتورة #${order.id.slice(-6).toUpperCase()}`, { pageNumbers: false }) }
            );
            document.body.removeChild(container);
        } else {
            success = await sharePdf(
                'print-area',
                `${'فاتورة'} ${order.id.slice(-6).toUpperCase()}`,
                `Invoice-${safeStoreSlug}-${order.id.slice(-6).toUpperCase()}.pdf`,
                { ...buildPdfBrandOptions(brandSettings, `فاتورة #${order.id.slice(-6).toUpperCase()}`, { pageNumbers: false }) }
            );
        }
        if (success) {
            showNotification('تم حفظ الفاتورة في مجلد المستندات', 'success');
        } else {
            showNotification('لا يمكن مشاركة الفاتورة. يرجى التأكد من منح التطبيق الصلاحيات اللازمة.', 'error');
        }
        setIsSharing(false);
    };

    const handlePrint = async () => {
        if (!order) return;

        const currentCount = typeof order.invoicePrintCount === 'number' ? order.invoicePrintCount : 0;
        if (currentCount > 0) {
            const ok = window.confirm('هذه إعادة طباعة وسيتم وضع علامة "نسخة" على الفاتورة. المتابعة؟');
            if (!ok) return;
        }

        if (Capacitor.isNativePlatform()) {
            setIsPrinting(true);
            sharePdf(
                'print-area',
                `${'فاتورة'} ${order.id.slice(-6).toUpperCase()}`,
                `Invoice-${safeStoreSlug}-${order.id.slice(-6).toUpperCase()}.pdf`,
                { ...buildPdfBrandOptions(settings, `فاتورة #${order.id.slice(-6).toUpperCase()}`, { pageNumbers: false }) }
            ).then((success) => {
                if (success) {
                    showNotification('اختر "طباعة" من خيارات المشاركة إذا كانت متاحة', 'success');
                    incrementInvoicePrintCount(order.id);
                } else {
                    showNotification('تعذر إنشاء ملف PDF للطباعة', 'error');
                }
            }).finally(() => setIsPrinting(false));
            return;
        }

        const brand = resolveBranding();
        const vatNumber = (settings.taxSettings?.taxNumber || '').trim();
        let qrCodeDataUrl: string | undefined = undefined;
        if (vatNumber) {
            const snap: any = (order as any).invoiceSnapshot || {};
            const issuedAt = String(snap.invoiceIssuedAt || (order as any).invoiceIssuedAt || order.createdAt || new Date().toISOString());
            const total = Number(snap.total ?? (order as any).total ?? 0).toFixed(2);
            const vatTotal = Number(snap.taxAmount ?? (order as any).taxAmount ?? 0).toFixed(2);
            try {
                const sellerName = AZTA_IDENTITY.tradeNameAr;
                const qrData = generateZatcaTLV(sellerName, vatNumber, issuedAt, total, vatTotal);
                qrCodeDataUrl = await QRCode.toDataURL(qrData, { width: 100, margin: 1 });
            } catch {
                qrCodeDataUrl = undefined;
            }
        }

        const content = renderToString(
            <PrintableInvoice
                order={order}
                audit={{ ...(invoiceAudit || {}), printedBy: (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null }}
                language="ar"
                companyName={brand.name}
                companyPhone={brand.contactNumber}
                companyAddress={brand.address}
                logoUrl={brand.logoUrl}
                vatNumber={vatNumber}
                deliveryZoneName={resolveDeliveryZoneName(order)}
                thermal
                thermalPaperWidth={thermalPaperWidth}
                isCopy={currentCount > 0}
                copyNumber={currentCount > 0 ? currentCount + 1 : undefined}
                qrCodeDataUrl={qrCodeDataUrl}
                costCenterLabel={costCenterLabel || undefined}
                creditSummary={creditSummary}
            />
        );
        printContent(content, `فاتورة #${order.id.slice(-6).toUpperCase()}`, { page: 'auto' });
        incrementInvoicePrintCount(order.id);
    };

    const handlePrintA4 = () => {
        if (!order) return;

        const currentCount = typeof order.invoicePrintCount === 'number' ? order.invoicePrintCount : 0;
        if (currentCount > 0) {
            const ok = window.confirm('هذه إعادة طباعة وسيتم وضع علامة "نسخة" على الفاتورة. المتابعة؟');
            if (!ok) return;
        }

        const brand = resolveBranding();
        const brandSettings: any = {
            ...settings,
            cafeteriaName: { ...(settings as any).cafeteriaName, ar: AZTA_IDENTITY.tradeNameAr, en: AZTA_IDENTITY.tradeNameEn },
            logoUrl: brand.logoUrl,
            address: brand.address,
            contactNumber: brand.contactNumber,
        };

        if (Capacitor.isNativePlatform()) {
            setIsPrintingA4(true);
            sharePdf(
                'print-area',
                `${'فاتورة'} ${order.id.slice(-6).toUpperCase()}`,
                `Invoice-${safeStoreSlug}-${order.id.slice(-6).toUpperCase()}.pdf`,
                { ...buildPdfBrandOptions(brandSettings, `فاتورة #${order.id.slice(-6).toUpperCase()}`, { pageNumbers: false }) }
            ).then((success) => {
                if (success) {
                    showNotification('اختر "طباعة" من خيارات المشاركة إذا كانت متاحة', 'success');
                    incrementInvoicePrintCount(order.id);
                } else {
                    showNotification('تعذر إنشاء ملف PDF للطباعة', 'error');
                }
            }).finally(() => setIsPrintingA4(false));
            return;
        }

        try {
            window.print();
            incrementInvoicePrintCount(order.id);
        } catch {
        }
    };

    const handlePrintA4WithPageNumbers = () => {
        if (!order) return;
        setIsPrintingA4Pdf(true);
        const brand = resolveBranding();
        const brandSettings: any = {
            ...settings,
            cafeteriaName: { ...(settings as any).cafeteriaName, ar: AZTA_IDENTITY.tradeNameAr, en: AZTA_IDENTITY.tradeNameEn },
            logoUrl: brand.logoUrl,
            address: brand.address,
            contactNumber: brand.contactNumber,
        };
        printPdfFromElement(
            'print-area',
            `${'فاتورة'} ${order.id.slice(-6).toUpperCase()}`,
            { ...buildPdfBrandOptions(brandSettings, `فاتورة #${order.id.slice(-6).toUpperCase()}`, { pageNumbers: true }) }
        ).then((success) => {
            if (success) {
                incrementInvoicePrintCount(order.id);
            }
        }).finally(() => setIsPrintingA4Pdf(false));
    };

    const handlePrintDeliveryNote = () => {
        if (!order) return;
        const brand = resolveBranding();
        const printedBy = (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null;
        const content = renderToString(
            <PrintableOrder
                order={order}
                language="ar"
                companyName={brand.name}
                companyAddress={brand.address}
                companyPhone={brand.contactNumber}
                logoUrl={brand.logoUrl}
                audit={{ printedBy }}
            />
        );
        printContent(content, `سند تسليم #${order.id.slice(-6).toUpperCase()}`);
    };

    const handlePrintDefault = () => {
        if (selectedTemplate === 'thermal') {
            void handlePrint();
        } else {
            handlePrintA4();
        }
    };

    const openPreviewDefault = () => {
        void openPreview(selectedTemplate);
    };

    const openPreview = async (kind: 'thermal' | 'a4') => {
        if (!order) return;
        setPreviewKind(kind);
        if (kind === 'thermal') {
            const currentCount = typeof order.invoicePrintCount === 'number' ? order.invoicePrintCount : 0;
            const brand = resolveBranding();
            const vatNumber = (settings.taxSettings?.taxNumber || '').trim();
            let qrCodeDataUrl: string | undefined = undefined;
            if (vatNumber) {
                const snap: any = (order as any).invoiceSnapshot || {};
                const issuedAt = String(snap.invoiceIssuedAt || (order as any).invoiceIssuedAt || order.createdAt || new Date().toISOString());
                const total = Number(snap.total ?? (order as any).total ?? 0).toFixed(2);
                const vatTotal = Number(snap.taxAmount ?? (order as any).taxAmount ?? 0).toFixed(2);
                try {
                    const sellerName = AZTA_IDENTITY.tradeNameAr;
                    const qrData = generateZatcaTLV(sellerName, vatNumber, issuedAt, total, vatTotal);
                    qrCodeDataUrl = await QRCode.toDataURL(qrData, { width: 100, margin: 1 });
                } catch {
                    qrCodeDataUrl = undefined;
                }
            }
            const content = renderToString(
                <PrintableInvoice
                    order={order}
                    audit={{ ...(invoiceAudit || {}), printedBy: (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null }}
                    language="ar"
                    companyName={brand.name}
                    companyPhone={brand.contactNumber}
                    companyAddress={brand.address}
                    logoUrl={brand.logoUrl}
                    vatNumber={vatNumber}
                    deliveryZoneName={resolveDeliveryZoneName(order)}
                    thermal
                    thermalPaperWidth={thermalPaperWidth}
                    isCopy={currentCount > 0}
                    copyNumber={currentCount > 0 ? currentCount + 1 : undefined}
                    qrCodeDataUrl={qrCodeDataUrl}
                    costCenterLabel={costCenterLabel || undefined}
                    creditSummary={creditSummary}
                />
            );
            setPreviewHtml(buildPrintHtml(content, `فاتورة #${order.id.slice(-6).toUpperCase()}`, { page: 'auto' }));
            setPreviewTitle('معاينة الطباعة الحرارية');
        } else {
            setPreviewHtml('');
            setPreviewTitle('معاينة طباعة A4');
        }
        setPreviewOpen(true);
    };

    useEffect(() => {
        const params = new URLSearchParams(location.search || '');
        const autoprint = params.get('autoprint') === '1';
        const thermal = params.get('thermal') === '1';
        const copies = Math.max(1, Number(params.get('copies') || 1));
        const orderIdSafe = order?.id || '';
        const invoiceIssuedAtSafe = (order as any)?.invoiceIssuedAt || '';
        const runKey = `${orderIdSafe}|${invoiceIssuedAtSafe}|${location.search || ''}`;
        if (orderIdSafe && invoiceIssuedAtSafe && autoprint && thermal) {
            if (autoPrintRunKeyRef.current === runKey) return;
            autoPrintRunKeyRef.current = runKey;
            let printed = 0;
            const run = () => {
                void handlePrint();
                printed += 1;
                if (printed < copies) {
                    window.setTimeout(run, 300);
                }
            };
            window.setTimeout(run, 100);
        }
    }, [location.search, order?.id, (order as any)?.invoiceIssuedAt]);

    if (!order && loading) {
        return <PageLoader />;
    }

    if (!order) {
        return (
            <div className="text-center p-8 bg-white dark:bg-gray-800 rounded-lg shadow-xl">
                <h2 className="text-2xl font-bold dark:text-white">الطلب غير موجود</h2>
                <Link to="/my-orders" className="mt-6 inline-block bg-orange-500 text-white font-bold py-2 px-6 rounded-lg hover:bg-orange-600">
                    طلباتي
                </Link>
            </div>
        );
    }

    if (!order.invoiceIssuedAt) {
        return (
            <div className="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8">
                <div className="my-6">
                    <button onClick={() => navigate(-1)} className="flex items-center text-sm font-semibold text-gray-600 dark:text-gray-300 hover:text-orange-500 dark:hover:text-orange-400 transition-colors">
                        <BackArrowIcon />
                        {'رجوع'}
                    </button>
                </div>
                <div className="text-center p-8 bg-white dark:bg-gray-800 rounded-lg shadow-xl">
                    <h2 className="text-2xl font-bold dark:text-white">الفاتورة غير متاحة بعد</h2>
                    <p className="text-gray-500 dark:text-gray-400 mt-3">تظهر الفاتورة بعد تسليم الطلب وإغلاقه.</p>
                    <Link to={`/order/${order.id}`} className="mt-6 inline-block bg-orange-500 text-white font-bold py-2 px-6 rounded-lg hover:bg-orange-600">
                        {'تتبع الطلب'}
                    </Link>
                </div>
            </div>
        );
    }

    const fxInfo = useMemo(() => {
        const snap: any = (order as any)?.invoiceSnapshot || {};
        const currency = String((snap.currency || (order as any)?.currency || '')).toUpperCase();
        const baseC = String((snap.baseCurrency || '')).toUpperCase();
        const fx = Number(snap.fxRate ?? (order as any)?.fxRate ?? 1) || 1;
        const baseTotal = Number((order as any)?.baseTotal) || undefined;
        const locked = Boolean((order as any)?.invoiceIssuedAt);
        return { currency, baseCurrency: baseC, fxRate: fx, baseTotal, locked };
    }, [order]);

    return (
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
            <div className="my-6 flex justify-between items-center gap-4">
                <button onClick={() => navigate(-1)} className="flex items-center text-sm font-semibold text-gray-600 dark:text-gray-300 hover:text-orange-500 dark:hover:text-orange-400 transition-colors">
                    <BackArrowIcon />
                    رجوع
                </button>
                <div className="flex items-center gap-2">
                    <div className="hidden sm:flex items-center gap-2 px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700">
                        <div className="flex flex-col">
                            <div className="text-xs text-gray-500 dark:text-gray-400">
                                {fxInfo.locked ? 'لقطة مثبتة' : 'غير مثبتة'}
                            </div>
                            <div className="text-xs text-gray-700 dark:text-gray-300" dir="ltr">
                                FX={fxInfo.fxRate ? fxInfo.fxRate.toFixed(6) : '—'}
                            </div>
                        </div>
                        <div className="border-l dark:border-gray-700 h-6" />
                        <CurrencyDualAmount
                            amount={Number((order as any)?.total || 0)}
                            currencyCode={fxInfo.currency || undefined}
                            baseAmount={fxInfo.baseTotal}
                            fxRate={fxInfo.fxRate || undefined}
                            baseCurrencyCode={fxInfo.baseCurrency || undefined}
                            compact
                        />
                    </div>
                    {isAdminInvoice && (
                        <div className="flex items-center gap-2 rounded-lg border border-gray-200 dark:border-gray-700 px-3 py-2">
                            <span className="text-xs font-semibold text-gray-600 dark:text-gray-300">القالب:</span>
                            <select
                                value={selectedTemplate}
                                onChange={(e) => setSelectedTemplate(e.target.value === 'thermal' ? 'thermal' : 'a4')}
                                className="text-xs bg-transparent border border-gray-200 dark:border-gray-700 rounded px-2 py-1 text-gray-800 dark:text-gray-200"
                            >
                                <option value="thermal">حراري</option>
                                <option value="a4">A4</option>
                            </select>
                        </div>
                    )}
                    {isAdminInvoice && (
                        <button
                            onClick={handlePrintDefault}
                            className="inline-flex items-center justify-center bg-indigo-600 text-white font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-indigo-700 transition-colors gap-2"
                        >
                            <PrinterIcon />
                            طباعة ({selectedTemplate === 'thermal' ? 'حراري' : 'A4'})
                        </button>
                    )}
                    {isAdminInvoice && (
                        <button
                            onClick={openPreviewDefault}
                            className="inline-flex items-center justify-center bg-indigo-50 text-indigo-700 font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-indigo-100 transition-colors gap-2 dark:bg-indigo-900/20 dark:text-indigo-200 dark:hover:bg-indigo-900/30"
                        >
                            معاينة
                        </button>
                    )}
                    <button
                        onClick={handlePrint}
                        disabled={isPrinting}
                        className="inline-flex items-center justify-center bg-blue-600 text-white font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-blue-700 transition-colors disabled:bg-blue-400 disabled:cursor-wait gap-2"
                    >
                        <PrinterIcon />
                        {isPrinting ? 'جاري التحميل...' : 'طباعة حرارية'}
                    </button>
                    {isAdminInvoice && (
                        <button
                            onClick={() => openPreview('thermal')}
                            className="inline-flex items-center justify-center bg-blue-50 text-blue-700 font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-blue-100 transition-colors gap-2 dark:bg-blue-900/20 dark:text-blue-200 dark:hover:bg-blue-900/30"
                        >
                            معاينة
                        </button>
                    )}
                    <button
                        onClick={handlePrintA4}
                        disabled={isPrintingA4}
                        className="inline-flex items-center justify-center bg-gray-800 text-white font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-gray-900 transition-colors disabled:bg-gray-500 disabled:cursor-wait gap-2"
                    >
                        <PrinterIcon />
                        {isPrintingA4 ? 'جاري التحميل...' : 'طباعة A4'}
                    </button>
                    {isAdminInvoice && (
                        <button
                            onClick={handlePrintA4WithPageNumbers}
                            disabled={isPrintingA4Pdf}
                            className="inline-flex items-center justify-center bg-gray-50 text-gray-900 font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-gray-100 transition-colors disabled:bg-gray-200 disabled:cursor-wait gap-2 dark:bg-gray-800 dark:text-gray-100 dark:hover:bg-gray-700"
                        >
                            <PrinterIcon />
                            {isPrintingA4Pdf ? 'جاري التحضير...' : 'A4 (ترقيم صفحات)'}
                        </button>
                    )}
                    {isAdminInvoice && (
                        <button
                            onClick={() => openPreview('a4')}
                            className="inline-flex items-center justify-center bg-gray-100 text-gray-900 font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-gray-200 transition-colors gap-2 dark:bg-gray-700 dark:text-gray-100 dark:hover:bg-gray-600"
                        >
                            معاينة
                        </button>
                    )}
                    {isAdminInvoice && (
                        <button
                            onClick={handlePrintDeliveryNote}
                            className="inline-flex items-center justify-center bg-gray-200 text-gray-900 font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-gray-300 transition-colors gap-2 dark:bg-gray-700 dark:text-gray-100 dark:hover:bg-gray-600"
                        >
                            طباعة سند تسليم
                        </button>
                    )}
                    <button
                        onClick={handleSharePdf}
                        disabled={isSharing}
                        className="inline-flex items-center justify-center bg-green-600 text-white font-bold py-2 px-4 rounded-lg shadow-lg hover:bg-green-700 transition-colors disabled:bg-green-400 disabled:cursor-wait gap-2"
                    >
                        <ShareIcon />
                        {isSharing ? 'جاري التحميل...' : 'مشاركة PDF'}
                    </button>
                </div>
            </div>

            <ConfirmationModal
                isOpen={previewOpen}
                onClose={() => setPreviewOpen(false)}
                onConfirm={() => {
                    setPreviewOpen(false);
                    if (previewKind === 'thermal') {
                        handlePrint();
                    } else {
                        handlePrintA4();
                    }
                }}
                title={previewTitle}
                message=""
                confirmText="طباعة"
                cancelText="إغلاق"
                confirmButtonClassName="bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400"
                maxWidthClassName="max-w-5xl"
            >
                {previewKind === 'thermal' ? (
                    <iframe
                        title="print-preview"
                        className="w-full h-[70dvh] bg-white rounded border border-gray-200"
                        srcDoc={previewHtml}
                    />
                ) : (
                    <div className="bg-white p-4 rounded border border-gray-200">
                        <div className="text-xs text-gray-500 mb-3">هذه معاينة A4 ضمن الواجهة. عند الطباعة قد تُطبّق قواعد @media print.</div>
                        {isAdminInvoice ? (
                            <TriplicateInvoice
                                ref={invoiceRef}
                                order={order}
                                settings={settings as any}
                                branding={resolveBranding()}
                                costCenterLabel={costCenterLabel || null}
                                creditSummary={creditSummary}
                                audit={{ printedBy: (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null }}
                            />
                        ) : (
                            <Invoice
                                ref={invoiceRef}
                                order={order}
                                settings={settings as any}
                                branding={resolveBranding()}
                                costCenterLabel={costCenterLabel || null}
                                creditSummary={creditSummary}
                                audit={{ printedBy: (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null }}
                            />
                        )}
                    </div>
                )}
            </ConfirmationModal>

            <div id="print-area">
                {isAdminInvoice && selectedTemplate === 'a4' ? (
                    <TriplicateInvoice
                        ref={invoiceRef}
                        order={order}
                        settings={settings as any}
                        branding={resolveBranding()}
                        costCenterLabel={costCenterLabel || null}
                        creditSummary={creditSummary}
                        audit={{ printedBy: (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null }}
                    />
                ) : (
                    <Invoice
                        ref={invoiceRef}
                        order={order}
                        settings={settings as any}
                        branding={resolveBranding()}
                        costCenterLabel={costCenterLabel || null}
                        creditSummary={creditSummary}
                        audit={{ printedBy: (adminUser?.fullName || adminUser?.username || adminUser?.email || '').trim() || null }}
                    />
                )}
            </div>
        </div>
    );
};

export default InvoiceScreen;
