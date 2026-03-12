import { useCallback, useEffect, useMemo, useState, useRef } from 'react';
import { renderToString } from 'react-dom/server';
import { useNavigate } from 'react-router-dom';
import { useToast } from '../../contexts/ToastContext';
import { useSettings } from '../../contexts/SettingsContext';
import { useMenu } from '../../contexts/MenuContext';
import { useItemMeta } from '../../contexts/ItemMetaContext';
import { useSessionScope } from '../../contexts/SessionScopeContext';
import { getBaseCurrencyCode, getSupabaseClient } from '../../supabase';
import { printContent } from '../../utils/printUtils';
import { localizeSupabaseError } from '../../utils/errorUtils';
import PrintableQuotation from '../../components/admin/PrintableQuotation';
import type { QuotationPrintData } from '../../components/admin/PrintableQuotation';

interface Quotation {
    id: string;
    quotation_number: string;
    customer_name: string;
    customer_phone: string;
    customer_company: string;
    customer_address: string;
    status: string;
    valid_until: string;
    currency: string;
    discount_type: string;
    discount_value: number;
    subtotal: number;
    discount_amount: number;
    tax_rate: number;
    tax_amount: number;
    total: number;
    notes: string;
    terms: string;
    created_by: string | null;
    created_at: string;
    updated_at: string;
}

interface QuotationItem {
    id: string;
    quotation_id: string;
    item_id: string | null;
    item_name: string;
    unit: string;
    quantity: number;
    unit_price: number;
    total: number;
    notes: string;
    sort_order: number;
}

const statusTranslations: Record<string, string> = {
    draft: 'مسودة',
    sent: 'مُرسل',
    accepted: 'مقبول',
    expired: 'منتهي',
    cancelled: 'ملغي',
};

const statusColors: Record<string, string> = {
    draft: 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200',
    sent: 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200',
    accepted: 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200',
    expired: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200',
    cancelled: 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
};

const roundMoney = (v: number) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return 0;
    return Math.round(n * 100) / 100;
};

const toYmd = (d: Date) => {
    const yyyy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd}`;
};

const QuotationsScreen: React.FC = () => {
    const { showNotification } = useToast();
    const { settings } = useSettings();
    const { menuItems: allMenuItems } = useMenu();
    const { unitTypes, getUnitLabel } = useItemMeta();
    const sessionScope = useSessionScope();
    const navigate = useNavigate();
    const fefoCache = useRef<Map<string, number>>(new Map());
    const [currencyOptions, setCurrencyOptions] = useState<string[]>([]);
    const [isRepricingAll, setIsRepricingAll] = useState(false);
    const repriceAbortRef = useRef<AbortController | null>(null);

    const menuItems = useMemo(() => {
        const items = allMenuItems.filter(i => i.status !== 'archived');
        items.sort((a, b) => {
            const an = a.name?.['ar'] || a.name?.en || '';
            const bn = b.name?.['ar'] || b.name?.en || '';
            return an.localeCompare(bn);
        });
        return items;
    }, [allMenuItems]);

    const unitOptions = useMemo(() => {
        const active = unitTypes.filter(u => u.isActive).map(u => ({
            value: String(u.key),
            label: getUnitLabel(String(u.key) as any, 'ar') || String(u.key),
        }));
        if (active.length > 0) return active;
        return [
            { value: 'piece', label: 'قطعة' },
            { value: 'kg', label: 'كجم' },
            { value: 'gram', label: 'جرام' },
        ];
    }, [unitTypes, getUnitLabel]);

    // State
    const [quotations, setQuotations] = useState<Quotation[]>([]);
    const [loading, setLoading] = useState(true);
    const [filterStatus, setFilterStatus] = useState<string>('all');
    const [searchQuery, setSearchQuery] = useState('');

    // Modal state
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [editingId, setEditingId] = useState<string | null>(null);
    const [isSaving, setIsSaving] = useState(false);

    // Form state
    const [formCustomerName, setFormCustomerName] = useState('');
    const [formCustomerPhone, setFormCustomerPhone] = useState('');
    const [formCustomerCompany, setFormCustomerCompany] = useState('');
    const [formCustomerAddress, setFormCustomerAddress] = useState('');
    const [formValidUntil, setFormValidUntil] = useState(toYmd(new Date(Date.now() + 15 * 86400000)));
    const [formCurrency, setFormCurrency] = useState('YER');
    const [baseCurrency, setBaseCurrency] = useState('YER');
    const [formDiscountType, setFormDiscountType] = useState('none');
    const [formDiscountValue, setFormDiscountValue] = useState(0);
    const [formTaxRate, setFormTaxRate] = useState(0);
    const [formNotes, setFormNotes] = useState('');
    const [formTerms, setFormTerms] = useState('');
    const [catalogCurrency, setCatalogCurrency] = useState('');
    const [formItems, setFormItems] = useState<Array<{
        id?: string;
        item_id: string | null;
        item_name: string;
        unit: string;
        quantity: number;
        unit_price: number;
        notes: string;
    }>>([]);

    // Item search
    const [itemSearch, setItemSearch] = useState('');

    // Delete confirm
    const [deleteId, setDeleteId] = useState<string | null>(null);
    const [isDeleting, setIsDeleting] = useState(false);

    // Computations
    const computedSubtotal = useMemo(() => {
        return roundMoney(formItems.reduce((sum, item) => sum + roundMoney(item.quantity * item.unit_price), 0));
    }, [formItems]);

    const computedDiscountAmount = useMemo(() => {
        if (formDiscountType === 'percentage') {
            return roundMoney(computedSubtotal * (formDiscountValue / 100));
        } else if (formDiscountType === 'fixed') {
            return roundMoney(Math.min(formDiscountValue, computedSubtotal));
        }
        return 0;
    }, [computedSubtotal, formDiscountType, formDiscountValue]);

    const computedTaxAmount = useMemo(() => {
        const taxable = computedSubtotal - computedDiscountAmount;
        return roundMoney(taxable * (formTaxRate / 100));
    }, [computedSubtotal, computedDiscountAmount, formTaxRate]);

    const computedTotal = useMemo(() => {
        return roundMoney(computedSubtotal - computedDiscountAmount + computedTaxAmount);
    }, [computedSubtotal, computedDiscountAmount, computedTaxAmount]);

    // Fetch quotations
    const fetchQuotations = useCallback(async () => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        setLoading(true);
        try {
            const { data, error } = await supabase
                .from('price_quotations')
                .select('*')
                .order('created_at', { ascending: false });
            if (error) throw error;
            setQuotations(Array.isArray(data) ? data as Quotation[] : []);
        } catch (err) {
            showNotification(localizeSupabaseError(err) || 'فشل تحميل عروض الأسعار', 'error');
        } finally {
            setLoading(false);
        }
    }, [showNotification]);

    useEffect(() => { void fetchQuotations(); }, [fetchQuotations]);
    useEffect(() => {
        void getBaseCurrencyCode().then((code) => {
            const normalized = String(code || '').trim().toUpperCase();
            if (!normalized) return;
            setBaseCurrency(normalized);
            setCatalogCurrency(prev => String(prev || '').trim().toUpperCase() || normalized);
            setFormCurrency(prev => {
                const current = String(prev || '').trim().toUpperCase();
                if (!current || current === 'YER') return normalized;
                return current;
            });
        });
    }, [baseCurrency]);

    // Fetch system currencies for dropdown
    useEffect(() => {
        let active = true;
        const run = async () => {
            try {
                // Try operational currencies from settings first
                const opCurrencies = Array.isArray((settings as any).operationalCurrencies) && (settings as any).operationalCurrencies.length
                    ? (settings as any).operationalCurrencies.map((c: any) => String(c || '').trim().toUpperCase()).filter(Boolean)
                    : [];
                if (opCurrencies.length > 0) {
                    if (active) setCurrencyOptions(Array.from(new Set(opCurrencies)));
                    return;
                }
                // Fallback: fetch from currencies table
                const supabase = getSupabaseClient();
                if (!supabase) return;
                const { data, error } = await supabase
                    .from('currencies')
                    .select('code')
                    .order('code', { ascending: true });
                if (error) throw error;
                const codes = (Array.isArray(data) ? data : [])
                    .map((r: any) => String(r?.code || '').trim().toUpperCase())
                    .filter(Boolean);
                if (active) setCurrencyOptions(Array.from(new Set(codes)));
            } catch {
                if (active) setCurrencyOptions([]);
            }
        };
        void run();
        return () => { active = false; };
    }, [settings]);

    // Filtered quotations
    const filteredQuotations = useMemo(() => {
        let list = quotations;
        if (filterStatus !== 'all') {
            list = list.filter(q => q.status === filterStatus);
        }
        if (searchQuery.trim()) {
            const q = searchQuery.trim().toLowerCase();
            list = list.filter(qt =>
                qt.customer_name?.toLowerCase().includes(q) ||
                qt.customer_company?.toLowerCase().includes(q) ||
                qt.quotation_number?.toLowerCase().includes(q) ||
                qt.customer_phone?.includes(q)
            );
        }
        return list;
    }, [quotations, filterStatus, searchQuery]);

    // Reset form
    const resetForm = useCallback(() => {
        setFormCustomerName('');
        setFormCustomerPhone('');
        setFormCustomerCompany('');
        setFormCustomerAddress('');
        setFormValidUntil(toYmd(new Date(Date.now() + 15 * 86400000)));
        setFormCurrency(baseCurrency || 'YER');
        setFormDiscountType('none');
        setFormDiscountValue(0);
        setFormTaxRate(0);
        setFormNotes('');
        setFormTerms('');
        setFormItems([]);
        setItemSearch('');
    }, [baseCurrency]);

    // Open create modal
    const openCreate = useCallback(() => {
        resetForm();
        setEditingId(null);
        setIsModalOpen(true);
    }, [resetForm]);

    // Open edit modal
    const openEdit = useCallback(async (q: Quotation) => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        setEditingId(q.id);
        setFormCustomerName(q.customer_name);
        setFormCustomerPhone(q.customer_phone || '');
        setFormCustomerCompany(q.customer_company || '');
        setFormCustomerAddress(q.customer_address || '');
        setFormValidUntil(q.valid_until || toYmd(new Date(Date.now() + 15 * 86400000)));
        setFormCurrency(String(q.currency || baseCurrency || 'YER').trim().toUpperCase());
        setFormDiscountType(q.discount_type || 'none');
        setFormDiscountValue(q.discount_value || 0);
        setFormTaxRate(q.tax_rate || 0);
        setFormNotes(q.notes || '');
        setFormTerms(q.terms || '');

        // Load items
        try {
            const { data, error } = await supabase
                .from('price_quotation_items')
                .select('*')
                .eq('quotation_id', q.id)
                .order('sort_order', { ascending: true });
            if (error) throw error;
            const items: QuotationItem[] = Array.isArray(data) ? data as QuotationItem[] : [];
            setFormItems(items.map(it => ({
                id: it.id,
                item_id: it.item_id,
                item_name: it.item_name,
                unit: it.unit || 'piece',
                quantity: it.quantity,
                unit_price: it.unit_price,
                notes: it.notes || '',
            })));
        } catch {
            setFormItems([]);
        }
        setIsModalOpen(true);
    }, [baseCurrency]);

    // Duplicate quotation
    const handleDuplicate = useCallback(async (q: Quotation) => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        setEditingId(null);
        setFormCustomerName('');
        setFormCustomerPhone('');
        setFormCustomerCompany('');
        setFormCustomerAddress('');
        setFormValidUntil(toYmd(new Date(Date.now() + 15 * 86400000)));
        setFormCurrency(String(q.currency || baseCurrency || 'YER').trim().toUpperCase());
        setFormDiscountType(q.discount_type || 'none');
        setFormDiscountValue(q.discount_value || 0);
        setFormTaxRate(q.tax_rate || 0);
        setFormNotes(q.notes || '');
        setFormTerms(q.terms || '');

        try {
            const { data, error } = await supabase
                .from('price_quotation_items')
                .select('*')
                .eq('quotation_id', q.id)
                .order('sort_order', { ascending: true });
            if (error) throw error;
            const items: QuotationItem[] = Array.isArray(data) ? data as QuotationItem[] : [];
            setFormItems(items.map(it => ({
                item_id: it.item_id,
                item_name: it.item_name,
                unit: it.unit || 'piece',
                quantity: it.quantity,
                unit_price: it.unit_price,
                notes: it.notes || '',
            })));
        } catch {
            setFormItems([]);
        }
        setIsModalOpen(true);
    }, []);

    // Shared FEFO pricing helper
    const fetchFefoPrice = useCallback(async (menuItemId: string, currency: string, warehouseId?: string): Promise<number | null> => {
        const cacheKey = `${menuItemId}_${warehouseId}_${currency}`;
        if (fefoCache.current.has(cacheKey)) {
            return fefoCache.current.get(cacheKey) || null;
        }
        if (!warehouseId) return null;
        try {
            const supabase = getSupabaseClient();
            if (!supabase) return null;
            const { data: fefoData } = await supabase.rpc('get_fefo_pricing', {
                p_item_id: menuItemId,
                p_warehouse_id: warehouseId,
                p_quantity: 1,
                p_customer_id: null,
                p_currency_code: String(currency || 'YER').trim().toUpperCase(),
                p_batch_id: null,
            });
            if (fefoData && Number(fefoData.suggested_price) > 0) {
                const price = Number(fefoData.suggested_price);
                fefoCache.current.set(cacheKey, price);
                return price;
            }
        } catch { /* fallback */ }
        return null;
    }, []);

    // Add item from menu with FEFO pricing
    const addItemFromMenu = useCallback(async (menuItemId: string) => {
        const mi = menuItems.find(m => m.id === menuItemId);
        if (!mi) return;
        const name = mi.name?.['ar'] || mi.name?.en || mi.id;
        let price = Number(mi.price) || 0;
        const unit = String(mi.unitType || 'piece');
        const currency = String(formCurrency || baseCurrency || 'YER').trim().toUpperCase();
        const warehouseId = sessionScope.scope?.warehouseId;

        const fefoPrice = await fetchFefoPrice(menuItemId, currency, warehouseId);
        if (fefoPrice !== null) price = fefoPrice;

        setFormItems(prev => [...prev, {
            item_id: mi.id,
            item_name: name,
            unit,
            quantity: 1,
            unit_price: price,
            notes: '',
        }]);
        setItemSearch('');
    }, [menuItems, sessionScope.scope?.warehouseId, formCurrency, baseCurrency, fetchFefoPrice]);

    // Add custom item
    const addCustomItem = useCallback(() => {
        setFormItems(prev => [...prev, {
            item_id: null,
            item_name: '',
            unit: 'piece',
            quantity: 1,
            unit_price: 0,
            notes: '',
        }]);
    }, []);

    // Remove item
    const removeItem = useCallback((index: number) => {
        setFormItems(prev => prev.filter((_, i) => i !== index));
    }, []);

    // Update item field
    const updateItem = useCallback((index: number, field: string, value: any) => {
        setFormItems(prev => prev.map((item, i) => {
            if (i !== index) return item;
            return { ...item, [field]: value };
        }));
    }, []);

    // Save quotation
    const handleSave = useCallback(async () => {
        if (!formCustomerName.trim()) {
            showNotification('يرجى إدخال اسم العميل', 'error');
            return;
        }
        if (formItems.length === 0) {
            showNotification('يرجى إضافة بند واحد على الأقل', 'error');
            return;
        }
        for (const item of formItems) {
            if (!item.item_name.trim()) {
                showNotification('يرجى تعبئة اسم كل بند', 'error');
                return;
            }
        }

        const supabase = getSupabaseClient();
        if (!supabase) return;
        setIsSaving(true);

        try {
            const quotationData = {
                customer_name: formCustomerName.trim(),
                customer_phone: formCustomerPhone.trim(),
                customer_company: formCustomerCompany.trim(),
                customer_address: formCustomerAddress.trim(),
                valid_until: formValidUntil,
                currency: formCurrency,
                discount_type: formDiscountType,
                discount_value: formDiscountValue,
                subtotal: computedSubtotal,
                discount_amount: computedDiscountAmount,
                tax_rate: formTaxRate,
                tax_amount: computedTaxAmount,
                total: computedTotal,
                notes: formNotes.trim(),
                terms: formTerms.trim(),
            };

            let quotationId = editingId;

            if (editingId) {
                // Update
                const { error } = await supabase
                    .from('price_quotations')
                    .update(quotationData)
                    .eq('id', editingId);
                if (error) throw error;

                // Delete old items
                const { error: delErr } = await supabase
                    .from('price_quotation_items')
                    .delete()
                    .eq('quotation_id', editingId);
                if (delErr) throw delErr;
            } else {
                // Insert
                const { data: ins, error } = await supabase
                    .from('price_quotations')
                    .insert(quotationData)
                    .select('id')
                    .single();
                if (error) throw error;
                quotationId = (ins as any).id;
            }

            // Insert items
            if (quotationId && formItems.length > 0) {
                const itemRows = formItems.map((item, idx) => ({
                    quotation_id: quotationId,
                    item_id: item.item_id || null,
                    item_name: item.item_name.trim(),
                    unit: item.unit,
                    quantity: item.quantity,
                    unit_price: item.unit_price,
                    total: roundMoney(item.quantity * item.unit_price),
                    notes: item.notes?.trim() || '',
                    sort_order: idx,
                }));
                const { error: itemErr } = await supabase
                    .from('price_quotation_items')
                    .insert(itemRows);
                if (itemErr) throw itemErr;
            }

            showNotification(editingId ? 'تم تحديث عرض السعر' : 'تم إنشاء عرض السعر', 'success');
            setIsModalOpen(false);
            resetForm();
            await fetchQuotations();
        } catch (err) {
            showNotification(localizeSupabaseError(err) || 'فشل حفظ عرض السعر', 'error');
        } finally {
            setIsSaving(false);
        }
    }, [computedDiscountAmount, computedSubtotal, computedTaxAmount, computedTotal, editingId, fetchQuotations, formCustomerAddress, formCustomerCompany, formCustomerName, formCustomerPhone, formCurrency, formDiscountType, formDiscountValue, formItems, formNotes, formTaxRate, formTerms, formValidUntil, resetForm, showNotification]);

    // Update status
    const handleStatusChange = useCallback(async (q: Quotation, newStatus: string) => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        try {
            const { error } = await supabase
                .from('price_quotations')
                .update({ status: newStatus })
                .eq('id', q.id);
            if (error) throw error;
            showNotification(`تم تحديث الحالة إلى: ${statusTranslations[newStatus] || newStatus}`, 'success');
            await fetchQuotations();
        } catch (err) {
            showNotification(localizeSupabaseError(err) || 'فشل تحديث الحالة', 'error');
        }
    }, [fetchQuotations, showNotification]);

    // Delete
    const handleDelete = useCallback(async () => {
        if (!deleteId) return;
        const supabase = getSupabaseClient();
        if (!supabase) return;
        setIsDeleting(true);
        try {
            const { error } = await supabase
                .from('price_quotations')
                .delete()
                .eq('id', deleteId);
            if (error) throw error;
            showNotification('تم حذف عرض السعر', 'success');
            setDeleteId(null);
            await fetchQuotations();
        } catch (err) {
            showNotification(localizeSupabaseError(err) || 'فشل الحذف', 'error');
        } finally {
            setIsDeleting(false);
        }
    }, [deleteId, fetchQuotations, showNotification]);

    // Print quotation with print number tracking
    const handlePrint = useCallback(async (q: Quotation) => {
        const supabase = getSupabaseClient();
        if (!supabase) return;

        try {
            const { data, error } = await supabase
                .from('price_quotation_items')
                .select('*')
                .eq('quotation_id', q.id)
                .order('sort_order', { ascending: true });
            if (error) throw error;
            const items: QuotationItem[] = Array.isArray(data) ? data as QuotationItem[] : [];

            // Track print number
            let printNumber = 1;
            try {
                const { data: pn } = await supabase.rpc('track_document_print', { p_source_table: 'price_quotations', p_source_id: q.id, p_template: 'PrintableQuotation' });
                printNumber = Number(pn) || 1;
            } catch { /* fallback */ }

            const fallback = {
                name: (settings.cafeteriaName?.['ar'] || settings.cafeteriaName?.en || '').trim(),
                address: (settings.address || '').trim(),
                contactNumber: (settings.contactNumber || '').trim(),
                logoUrl: (settings.logoUrl || '').trim(),
                vatNumber: ((settings as any).vatNumber || '').trim(),
            };

            const printData: QuotationPrintData = {
                quotationNumber: q.quotation_number,
                createdAt: q.created_at,
                validUntil: q.valid_until,
                customerName: q.customer_name,
                customerPhone: q.customer_phone,
                customerCompany: q.customer_company,
                customerAddress: q.customer_address,
                currency: q.currency,
                items: items.map(it => ({
                    itemName: it.item_name,
                    unit: it.unit || 'piece',
                    quantity: it.quantity,
                    unitPrice: it.unit_price,
                    total: it.total,
                    notes: it.notes,
                })),
                subtotal: q.subtotal,
                discountType: q.discount_type,
                discountValue: q.discount_value,
                discountAmount: q.discount_amount,
                taxRate: q.tax_rate,
                taxAmount: q.tax_amount,
                total: q.total,
                notes: q.notes,
                terms: q.terms,
            };

            const content = renderToString(
                <PrintableQuotation
                    data={printData}
                    language="ar"
                    companyName={fallback.name}
                    companyAddress={fallback.address}
                    companyPhone={fallback.contactNumber}
                    logoUrl={fallback.logoUrl}
                    vatNumber={fallback.vatNumber}
                    printNumber={printNumber}
                />
            );
            printContent(content, `عرض سعر #${q.quotation_number}`);
        } catch (err) {
            showNotification(localizeSupabaseError(err) || 'فشل طباعة عرض السعر', 'error');
        }
    }, [settings, showNotification]);

    // Convert quotation to order
    const handleConvertToOrder = useCallback(async (q: Quotation) => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        try {
            const { data, error } = await supabase
                .from('price_quotation_items')
                .select('*')
                .eq('quotation_id', q.id)
                .order('sort_order', { ascending: true });
            if (error) throw error;
            const items: QuotationItem[] = Array.isArray(data) ? data as QuotationItem[] : [];

            // Navigate to orders with quotation data pre-filled
            navigate('/admin/orders', {
                state: {
                    fromQuotation: {
                        quotationId: q.id,
                        quotationNumber: q.quotation_number,
                        customerName: q.customer_name,
                        customerPhone: q.customer_phone,
                        items: items.map(it => ({
                            itemId: it.item_id,
                            itemName: it.item_name,
                            unit: it.unit,
                            quantity: it.quantity,
                            unitPrice: it.unit_price,
                        })),
                        discountType: q.discount_type,
                        discountValue: q.discount_value,
                        currency: q.currency,
                        notes: q.notes,
                    }
                }
            });

            if (q.status === 'draft') {
                await supabase
                    .from('price_quotations')
                    .update({ status: 'sent' })
                    .eq('id', q.id);
            }

            showNotification('تم تحويل العرض إلى طلب — اختر العميل وأكمل البيع', 'success');
        } catch (err) {
            showNotification(localizeSupabaseError(err) || 'فشل تحويل العرض', 'error');
        }
    }, [navigate, showNotification]);

    const formatDate = (dateStr: string) => {
        try {
            return new Date(dateStr).toLocaleDateString('ar-EG', { year: 'numeric', month: 'short', day: 'numeric' });
        } catch {
            return dateStr;
        }
    };

    const formatMoney = (v: number) => {
        const n = Number(v) || 0;
        try {
            return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        } catch {
            return n.toFixed(2);
        }
    };

    // Filtered menu items for search
    const filteredMenuItems = useMemo(() => {
        if (!itemSearch.trim()) return [];
        const q = itemSearch.trim().toLowerCase();
        return menuItems
            .filter(m => {
                const name = m.name?.['ar'] || m.name?.en || m.id;
                return name.toLowerCase().includes(q) || m.id.toLowerCase().includes(q);
            })
            .slice(0, 10);
    }, [itemSearch, menuItems]);

    // Add ALL menu items at once with FEFO pricing
    const addAllMenuItems = useCallback(async () => {
        const currency = String(formCurrency || baseCurrency || 'YER').trim().toUpperCase();
        const warehouseId = sessionScope.scope?.warehouseId;
        setIsRepricingAll(true);
        try {
            const results = await Promise.allSettled(
                menuItems.map(async (mi) => {
                    let price = Number(mi.price) || 0;
                    if (warehouseId) {
                        const fefoPrice = await fetchFefoPrice(mi.id, currency, warehouseId);
                        if (fefoPrice !== null) price = fefoPrice;
                    }
                    return {
                        item_id: mi.id,
                        item_name: mi.name?.['ar'] || mi.name?.en || mi.id,
                        unit: String(mi.unitType || 'piece'),
                        quantity: 1,
                        unit_price: price,
                        notes: '',
                    };
                })
            );
            const newItems = results
                .filter((r): r is PromiseFulfilledResult<any> => r.status === 'fulfilled')
                .map(r => r.value);
            setFormItems(newItems);
            showNotification(`تم إضافة ${newItems.length} صنف بتسعير ${currency}`, 'success');
        } finally {
            setIsRepricingAll(false);
        }
    }, [menuItems, showNotification, formCurrency, baseCurrency, sessionScope.scope?.warehouseId, fetchFefoPrice]);

    // Re-price all items when currency changes
    useEffect(() => {
        if (!isModalOpen) return;
        if (formItems.length === 0) return;
        const currency = String(formCurrency || baseCurrency || 'YER').trim().toUpperCase();
        const warehouseId = sessionScope.scope?.warehouseId;
        if (!warehouseId) return;

        // Only re-price items that have an item_id (system items, not custom)
        const itemsWithId = formItems.filter(it => Boolean(it.item_id));
        if (itemsWithId.length === 0) return;

        // Abort previous re-price
        if (repriceAbortRef.current) repriceAbortRef.current.abort();
        const controller = new AbortController();
        repriceAbortRef.current = controller;

        // Clear FEFO cache for this currency change
        fefoCache.current.clear();
        setIsRepricingAll(true);

        void (async () => {
            try {
                const priceMap = new Map<string, number>();
                await Promise.allSettled(
                    itemsWithId.map(async (it) => {
                        if (controller.signal.aborted) return;
                        const fefoPrice = await fetchFefoPrice(it.item_id!, currency, warehouseId);
                        if (fefoPrice !== null) priceMap.set(it.item_id!, fefoPrice);
                    })
                );
                if (controller.signal.aborted) return;
                if (priceMap.size > 0) {
                    setFormItems(prev => prev.map(it => {
                        if (!it.item_id || !priceMap.has(it.item_id)) return it;
                        return { ...it, unit_price: priceMap.get(it.item_id)! };
                    }));
                }
            } finally {
                if (!controller.signal.aborted) setIsRepricingAll(false);
            }
        })();

        return () => { controller.abort(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [formCurrency]);

    // Quick print: instant price catalog for ALL items
    const handlePrintCatalog = useCallback(async () => {
        if (menuItems.length === 0) {
            showNotification('لا توجد أصناف في النظام', 'error');
            return;
        }

        const catalogCurrencyCode = String(catalogCurrency || baseCurrency || 'YER').trim().toUpperCase();
        const warehouseId = sessionScope.scope?.warehouseId;

        // Fetch FEFO prices for catalog too
        let allItems: Array<{ itemName: string; unit: string; quantity: number; unitPrice: number; total: number }> = [];
        if (warehouseId) {
            setIsRepricingAll(true);
            try {
                const results = await Promise.allSettled(
                    menuItems.map(async (mi) => {
                        let price = Number(mi.price) || 0;
                        const fefoPrice = await fetchFefoPrice(mi.id, catalogCurrencyCode, warehouseId);
                        if (fefoPrice !== null) price = fefoPrice;
                        return {
                            itemName: mi.name?.['ar'] || mi.name?.en || mi.id,
                            unit: String(mi.unitType || 'piece'),
                            quantity: 1,
                            unitPrice: price,
                            total: price,
                        };
                    })
                );
                allItems = results
                    .filter((r): r is PromiseFulfilledResult<any> => r.status === 'fulfilled')
                    .map(r => r.value);
            } finally {
                setIsRepricingAll(false);
            }
        } else {
            allItems = menuItems.map(mi => ({
                itemName: mi.name?.['ar'] || mi.name?.en || mi.id,
                unit: String(mi.unitType || 'piece'),
                quantity: 1,
                unitPrice: Number(mi.price) || 0,
                total: Number(mi.price) || 0,
            }));
        }

        const subtotal = roundMoney(allItems.reduce((s, i) => s + i.total, 0));

        const fallback = {
            name: (settings.cafeteriaName?.['ar'] || settings.cafeteriaName?.en || '').trim(),
            address: (settings.address || '').trim(),
            contactNumber: (settings.contactNumber || '').trim(),
            logoUrl: (settings.logoUrl || '').trim(),
            vatNumber: ((settings as any).vatNumber || '').trim(),
        };

        const printData: QuotationPrintData = {
            quotationNumber: 'كتالوج أسعار',
            createdAt: new Date().toISOString(),
            validUntil: toYmd(new Date(Date.now() + 15 * 86400000)),
            customerName: '',
            currency: catalogCurrencyCode,
            items: allItems,
            subtotal,
            discountType: 'none',
            discountValue: 0,
            discountAmount: 0,
            taxRate: 0,
            taxAmount: 0,
            total: subtotal,
        };

        const content = renderToString(
            <PrintableQuotation
                data={printData}
                language="ar"
                companyName={fallback.name}
                companyAddress={fallback.address}
                companyPhone={fallback.contactNumber}
                logoUrl={fallback.logoUrl}
                vatNumber={fallback.vatNumber}
            />
        );
        printContent(content, 'كتالوج الأسعار');
    }, [menuItems, settings, showNotification, baseCurrency, catalogCurrency, sessionScope.scope?.warehouseId, fetchFefoPrice]);

    return (
        <div className="p-4 md:p-6 max-w-7xl mx-auto" dir="rtl">
            {/* Header */}
            <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-4 mb-6">
                <div>
                    <h1 className="text-2xl font-bold text-gray-900 dark:text-white">عروض الأسعار</h1>
                    <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">إنشاء وإدارة عروض الأسعار للعملاء والموزعين</p>
                </div>
                <div className="flex items-center gap-2 flex-wrap">
                    <select
                        value={catalogCurrency}
                        onChange={(e) => setCatalogCurrency(String(e.target.value || '').trim().toUpperCase())}
                        className="px-3 py-2.5 w-32 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-emerald-500"
                        title="عملة طباعة الكتالوج"
                    >
                        {(currencyOptions.length > 0 ? currencyOptions : [baseCurrency || 'YER']).map(code => (
                            <option key={code} value={code}>{code}</option>
                        ))}
                    </select>
                    <button
                        onClick={handlePrintCatalog}
                        className="px-4 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg font-medium transition-colors shadow-sm flex items-center gap-2"
                        title={`طباعة كتالوج بكل أصناف النظام فوراً (${String(catalogCurrency || baseCurrency || 'YER').trim().toUpperCase()})`}
                    >
                        🖨️ كتالوج الأسعار
                    </button>
                    <button
                        onClick={openCreate}
                        className="px-5 py-2.5 bg-indigo-600 hover:bg-indigo-700 text-white rounded-lg font-medium transition-colors shadow-sm flex items-center gap-2"
                    >
                        <span className="text-lg">+</span>
                        عرض سعر جديد
                    </button>
                </div>
            </div>

            {/* Filters */}
            <div className="flex flex-col md:flex-row gap-3 mb-6">
                <input
                    type="text"
                    placeholder="بحث بالاسم أو الشركة أو رقم العرض..."
                    value={searchQuery}
                    onChange={e => setSearchQuery(e.target.value)}
                    className="flex-1 px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
                />
                <select
                    value={filterStatus}
                    onChange={e => setFilterStatus(e.target.value)}
                    className="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500"
                >
                    <option value="all">جميع الحالات</option>
                    <option value="draft">مسودة</option>
                    <option value="sent">مُرسل</option>
                    <option value="accepted">مقبول</option>
                    <option value="expired">منتهي</option>
                    <option value="cancelled">ملغي</option>
                </select>
            </div>

            {/* Quotations table */}
            {loading ? (
                <div className="text-center py-16 text-gray-400">جاري التحميل...</div>
            ) : filteredQuotations.length === 0 ? (
                <div className="text-center py-16 bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700">
                    <div className="text-5xl mb-4">📋</div>
                    <p className="text-gray-500 dark:text-gray-400 text-lg">لا توجد عروض أسعار</p>
                    <p className="text-gray-400 dark:text-gray-500 text-sm mt-1">اضغط "عرض سعر جديد" لإنشاء أول عرض</p>
                </div>
            ) : (
                <div className="overflow-x-auto bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 shadow-sm">
                    <table className="w-full">
                        <thead>
                            <tr className="border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/40">
                                <th className="px-4 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400">رقم العرض</th>
                                <th className="px-4 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400">العميل</th>
                                <th className="px-4 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400">التاريخ</th>
                                <th className="px-4 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400">صالح حتى</th>
                                <th className="px-4 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400">الإجمالي</th>
                                <th className="px-4 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400">الحالة</th>
                                <th className="px-4 py-3 text-center text-xs font-medium text-gray-500 dark:text-gray-400">الإجراءات</th>
                            </tr>
                        </thead>
                        <tbody className="divide-y divide-gray-200 dark:divide-gray-700">
                            {filteredQuotations.map(q => (
                                <tr key={q.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/30 transition-colors">
                                    <td className="px-4 py-3 font-mono text-sm font-bold text-indigo-600 dark:text-indigo-400">{q.quotation_number}</td>
                                    <td className="px-4 py-3">
                                        <div className="font-medium text-gray-900 dark:text-white">{q.customer_name || '—'}</div>
                                        {q.customer_company && <div className="text-xs text-gray-400">{q.customer_company}</div>}
                                    </td>
                                    <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">{formatDate(q.created_at)}</td>
                                    <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">{formatDate(q.valid_until)}</td>
                                    <td className="px-4 py-3 font-bold text-sm">{formatMoney(q.total)} <span className="text-xs text-gray-400">{q.currency}</span></td>
                                    <td className="px-4 py-3">
                                        <span className={`inline-flex px-2.5 py-0.5 rounded-full text-xs font-medium ${statusColors[q.status] || ''}`}>
                                            {statusTranslations[q.status] || q.status}
                                        </span>
                                    </td>
                                    <td className="px-4 py-3 text-center">
                                        <div className="flex items-center justify-center gap-1 flex-wrap">
                                            <button onClick={() => handlePrint(q)} title="طباعة" className="p-1.5 text-gray-500 hover:text-indigo-600 dark:text-gray-400 dark:hover:text-indigo-400 transition-colors">🖨️</button>
                                            {(q.status === 'draft' || q.status === 'sent') && (
                                                <button onClick={() => handleConvertToOrder(q)} title="تحويل إلى طلب" className="p-1.5 text-gray-500 hover:text-emerald-600 dark:text-gray-400 dark:hover:text-emerald-400 transition-colors">🛒</button>
                                            )}
                                            <button onClick={() => openEdit(q)} title="تعديل" className="p-1.5 text-gray-500 hover:text-indigo-600 dark:text-gray-400 dark:hover:text-indigo-400 transition-colors">✏️</button>
                                            <button onClick={() => handleDuplicate(q)} title="نسخ" className="p-1.5 text-gray-500 hover:text-green-600 dark:text-gray-400 dark:hover:text-green-400 transition-colors">📋</button>
                                            {q.status === 'draft' && (
                                                <button onClick={() => handleStatusChange(q, 'sent')} title="إرسال" className="p-1.5 text-gray-500 hover:text-blue-600 dark:text-gray-400 dark:hover:text-blue-400 transition-colors">📤</button>
                                            )}
                                            {q.status === 'sent' && (
                                                <button onClick={() => handleStatusChange(q, 'accepted')} title="قبول" className="p-1.5 text-gray-500 hover:text-green-600 dark:text-gray-400 dark:hover:text-green-400 transition-colors">✅</button>
                                            )}
                                            {(q.status === 'draft' || q.status === 'sent') && (
                                                <button onClick={() => handleStatusChange(q, 'cancelled')} title="إلغاء" className="p-1.5 text-gray-500 hover:text-orange-600 dark:text-gray-400 dark:hover:text-orange-400 transition-colors">🚫</button>
                                            )}
                                            <button onClick={() => setDeleteId(q.id)} title="حذف" className="p-1.5 text-gray-500 hover:text-red-600 dark:text-gray-400 dark:hover:text-red-400 transition-colors">🗑️</button>
                                        </div>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}

            {/* Create/Edit Modal */}
            {isModalOpen && (
                <div className="fixed inset-0 bg-black/50 flex items-start justify-center z-50 overflow-y-auto py-8">
                    <div className="bg-white dark:bg-gray-800 rounded-2xl shadow-2xl w-full max-w-4xl mx-4" dir="rtl">
                        {/* Modal header */}
                        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-700">
                            <h2 className="text-xl font-bold text-gray-900 dark:text-white">
                                {editingId ? 'تعديل عرض السعر' : 'عرض سعر جديد'}
                            </h2>
                            <button onClick={() => setIsModalOpen(false)} className="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 text-2xl leading-none">&times;</button>
                        </div>

                        <div className="p-6 max-h-[75vh] overflow-y-auto space-y-6">
                            {/* Customer info */}
                            <div>
                                <h3 className="font-bold text-gray-700 dark:text-gray-300 mb-3">بيانات العميل</h3>
                                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                                    <div>
                                        <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">اسم العميل *</label>
                                        <input type="text" value={formCustomerName} onChange={e => setFormCustomerName(e.target.value)}
                                            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500" placeholder="اسم العميل" />
                                    </div>
                                    <div>
                                        <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">الهاتف</label>
                                        <input type="text" value={formCustomerPhone} onChange={e => setFormCustomerPhone(e.target.value)}
                                            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500" placeholder="رقم الهاتف" dir="ltr" />
                                    </div>
                                    <div>
                                        <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">اسم الشركة</label>
                                        <input type="text" value={formCustomerCompany} onChange={e => setFormCustomerCompany(e.target.value)}
                                            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500" placeholder="اسم الشركة / المؤسسة" />
                                    </div>
                                    <div>
                                        <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">العنوان</label>
                                        <input type="text" value={formCustomerAddress} onChange={e => setFormCustomerAddress(e.target.value)}
                                            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500" placeholder="العنوان" />
                                    </div>
                                </div>
                            </div>

                            {/* Items */}
                            <div>
                                <div className="flex items-center justify-between mb-3">
                                    <h3 className="font-bold text-gray-700 dark:text-gray-300">البنود</h3>
                                    <div className="flex items-center gap-2">
                                        <button onClick={addAllMenuItems}
                                            className="text-sm px-3 py-1 bg-emerald-100 dark:bg-emerald-900/30 hover:bg-emerald-200 dark:hover:bg-emerald-800/40 text-emerald-700 dark:text-emerald-300 rounded-lg transition-colors font-medium">
                                            📦 كل الأصناف
                                        </button>
                                        <button onClick={addCustomItem}
                                            className="text-sm px-3 py-1 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-300 rounded-lg transition-colors">
                                            + بند مخصص
                                        </button>
                                    </div>
                                </div>

                                {/* Item search */}
                                <div className="relative mb-3">
                                    <input
                                        type="text"
                                        value={itemSearch}
                                        onChange={e => setItemSearch(e.target.value)}
                                        placeholder="ابحث عن منتج لإضافته..."
                                        className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 placeholder-gray-400"
                                    />
                                    {filteredMenuItems.length > 0 && (
                                        <div className="absolute z-10 w-full mt-1 bg-white dark:bg-gray-700 border border-gray-200 dark:border-gray-600 rounded-lg shadow-lg max-h-48 overflow-y-auto">
                                            {filteredMenuItems.map(mi => (
                                                <button key={mi.id} onClick={() => addItemFromMenu(mi.id)}
                                                    className="w-full text-right px-3 py-2 hover:bg-indigo-50 dark:hover:bg-indigo-900/30 text-sm text-gray-800 dark:text-gray-200 flex justify-between items-center border-b border-gray-100 dark:border-gray-600 last:border-0">
                                                    <span>{mi.name?.['ar'] || mi.name?.en || mi.id}</span>
                                                    <span className="text-gray-400 text-xs">{formatMoney(Number(mi.price) || 0)}</span>
                                                </button>
                                            ))}
                                        </div>
                                    )}
                                </div>

                                {/* Items list */}
                                {formItems.length === 0 ? (
                                    <div className="text-center py-8 text-gray-400 dark:text-gray-500 bg-gray-50 dark:bg-gray-900/30 rounded-lg border border-dashed border-gray-300 dark:border-gray-600">
                                        ابحث عن منتج أو أضف بند مخصص
                                    </div>
                                ) : (
                                    <div className="space-y-3">
                                        {formItems.map((item, index) => (
                                            <div key={index} className="p-3 bg-gray-50 dark:bg-gray-900/30 rounded-lg border border-gray-200 dark:border-gray-600">
                                                <div className="flex items-start gap-3">
                                                    <span className="text-xs text-gray-400 mt-2 font-bold min-w-[20px]">{index + 1}</span>
                                                    <div className="flex-1 grid grid-cols-2 md:grid-cols-5 gap-2">
                                                        <div className="col-span-2 md:col-span-2">
                                                            <input type="text" value={item.item_name} onChange={e => updateItem(index, 'item_name', e.target.value)}
                                                                className="w-full px-2 py-1.5 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white"
                                                                placeholder="اسم البند" />
                                                        </div>
                                                        <div>
                                                            <select value={item.unit} onChange={e => updateItem(index, 'unit', e.target.value)}
                                                                className="w-full px-2 py-1.5 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white">
                                                                {unitOptions.map(u => <option key={u.value} value={u.value}>{u.label}</option>)}
                                                            </select>
                                                        </div>
                                                        <div>
                                                            <input type="number" min={0} step="any" value={item.quantity} onChange={e => updateItem(index, 'quantity', Number(e.target.value) || 0)}
                                                                className="w-full px-2 py-1.5 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white text-center"
                                                                placeholder="الكمية" />
                                                        </div>
                                                        <div>
                                                            <input type="number" min={0} step="any" value={item.unit_price} onChange={e => updateItem(index, 'unit_price', Number(e.target.value) || 0)}
                                                                className="w-full px-2 py-1.5 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white text-center"
                                                                placeholder="سعر الوحدة" />
                                                        </div>
                                                    </div>
                                                    <div className="flex flex-col items-end gap-1">
                                                        <span className="font-bold text-sm text-indigo-600 dark:text-indigo-400 whitespace-nowrap">
                                                            {formatMoney(roundMoney(item.quantity * item.unit_price))}
                                                        </span>
                                                        <button onClick={() => removeItem(index)} className="text-red-400 hover:text-red-600 text-xs">حذف</button>
                                                    </div>
                                                </div>
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </div>

                            {/* Settings row */}
                            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                                <div>
                                    <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">صالح حتى</label>
                                    <input type="date" value={formValidUntil} onChange={e => setFormValidUntil(e.target.value)}
                                        className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500" />
                                </div>
                                <div>
                                    <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">العملة</label>
                                    <select value={formCurrency} onChange={e => setFormCurrency(String(e.target.value || '').trim().toUpperCase())}
                                        className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500">
                                        {(currencyOptions.length > 0 ? currencyOptions : [baseCurrency || 'YER']).map(code => (
                                            <option key={code} value={code}>{code}</option>
                                        ))}
                                    </select>
                                    {isRepricingAll && <span className="text-xs text-amber-500 mt-1 block">⏳ جاري تحديث الأسعار...</span>}
                                </div>
                                <div>
                                    <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">نسبة الضريبة %</label>
                                    <input type="number" min={0} max={100} step="any" value={formTaxRate} onChange={e => setFormTaxRate(Number(e.target.value) || 0)}
                                        className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500" />
                                </div>
                            </div>

                            {/* Discount */}
                            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                                <div>
                                    <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">نوع الخصم</label>
                                    <select value={formDiscountType} onChange={e => setFormDiscountType(e.target.value)}
                                        className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500">
                                        <option value="none">بدون خصم</option>
                                        <option value="percentage">نسبة مئوية</option>
                                        <option value="fixed">مبلغ ثابت</option>
                                    </select>
                                </div>
                                {formDiscountType !== 'none' && (
                                    <div>
                                        <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">
                                            {formDiscountType === 'percentage' ? 'نسبة الخصم %' : 'مبلغ الخصم'}
                                        </label>
                                        <input type="number" min={0} step="any" value={formDiscountValue} onChange={e => setFormDiscountValue(Number(e.target.value) || 0)}
                                            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500" />
                                    </div>
                                )}
                            </div>

                            {/* Notes and Terms */}
                            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                                <div>
                                    <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">ملاحظات</label>
                                    <textarea rows={3} value={formNotes} onChange={e => setFormNotes(e.target.value)}
                                        className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 resize-none"
                                        placeholder="ملاحظات إضافية..." />
                                </div>
                                <div>
                                    <label className="block text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">الشروط والأحكام</label>
                                    <textarea rows={3} value={formTerms} onChange={e => setFormTerms(e.target.value)}
                                        className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 resize-none"
                                        placeholder="شروط الدفع والتسليم..." />
                                </div>
                            </div>

                            {/* Summary */}
                            <div className="bg-indigo-50 dark:bg-indigo-900/20 rounded-xl p-4 border border-indigo-200 dark:border-indigo-800">
                                <div className="space-y-2 text-sm">
                                    <div className="flex justify-between">
                                        <span className="text-gray-600 dark:text-gray-400">المجموع الفرعي:</span>
                                        <span className="font-mono font-bold">{formatMoney(computedSubtotal)}</span>
                                    </div>
                                    {computedDiscountAmount > 0 && (
                                        <div className="flex justify-between text-red-600 dark:text-red-400">
                                            <span>الخصم:</span>
                                            <span className="font-mono">- {formatMoney(computedDiscountAmount)}</span>
                                        </div>
                                    )}
                                    {computedTaxAmount > 0 && (
                                        <div className="flex justify-between">
                                            <span className="text-gray-600 dark:text-gray-400">الضريبة ({formTaxRate}%):</span>
                                            <span className="font-mono">{formatMoney(computedTaxAmount)}</span>
                                        </div>
                                    )}
                                    <div className="flex justify-between pt-2 border-t border-indigo-300 dark:border-indigo-700 text-lg font-bold text-indigo-800 dark:text-indigo-200">
                                        <span>الإجمالي:</span>
                                        <span className="font-mono">{formatMoney(computedTotal)} {formCurrency}</span>
                                    </div>
                                </div>
                            </div>
                        </div>

                        {/* Modal footer */}
                        <div className="flex items-center justify-between px-6 py-4 border-t border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/40 rounded-b-2xl">
                            <button onClick={() => setIsModalOpen(false)} className="px-5 py-2 text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-200 font-medium transition-colors">
                                إلغاء
                            </button>
                            <button onClick={handleSave} disabled={isSaving}
                                className="px-6 py-2.5 bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white rounded-lg font-medium transition-colors shadow-sm">
                                {isSaving ? 'جاري الحفظ...' : editingId ? 'تحديث العرض' : 'إنشاء العرض'}
                            </button>
                        </div>
                    </div>
                </div>
            )}

            {/* Delete confirmation */}
            {deleteId && (
                <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow-2xl p-6 max-w-sm mx-4" dir="rtl">
                        <h3 className="text-lg font-bold text-gray-900 dark:text-white mb-2">تأكيد الحذف</h3>
                        <p className="text-gray-600 dark:text-gray-400 mb-6">هل تريد حذف عرض السعر نهائياً؟ لا يمكن التراجع عن هذا الإجراء.</p>
                        <div className="flex justify-end gap-3">
                            <button onClick={() => setDeleteId(null)} className="px-4 py-2 text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-200 font-medium">إلغاء</button>
                            <button onClick={handleDelete} disabled={isDeleting}
                                className="px-4 py-2 bg-red-600 hover:bg-red-700 disabled:opacity-50 text-white rounded-lg font-medium transition-colors">
                                {isDeleting ? 'جاري الحذف...' : 'حذف'}
                            </button>
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
};

export default QuotationsScreen;
