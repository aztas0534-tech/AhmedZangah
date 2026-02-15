import React, { useEffect, useMemo, useState } from 'react';
import { useMenu } from '../../contexts/MenuContext';
import { usePriceHistory } from '../../contexts/PriceContext';
import type { MenuItem, PriceHistory } from '../../types';
import { useItemMeta } from '../../contexts/ItemMetaContext';
import { useToast } from '../../contexts/ToastContext';
import CurrencyDualAmount from '../../components/common/CurrencyDualAmount';
import { getBaseCurrencyCode, getOperationalFxRate, getSupabaseClient } from '../../supabase';
import { localizeSupabaseError } from '../../utils/errorUtils';

const ManagePricesScreen: React.FC = () => {
    const { menuItems } = useMenu();
    const { updatePrice, getPriceHistoryByItemId } = usePriceHistory();
    const { categories: categoryDefs, getCategoryLabel, getGroupLabel, getUnitLabel } = useItemMeta();
    const { showNotification } = useToast();
    const [baseCode, setBaseCode] = useState('—');
    const [searchTerm, setSearchTerm] = useState('');
    const [selectedCategory, setSelectedCategory] = useState('all');
    const [selectedGroup, setSelectedGroup] = useState('all');
    const [selectedItem, setSelectedItem] = useState<string | null>(null);
    const [newPrice, setNewPrice] = useState('');
    const [editingCurrency, setEditingCurrency] = useState<string>(''); // baseCode or YER
    const [reason, setReason] = useState('');
    const [currencyPriceMap, setCurrencyPriceMap] = useState<Record<string, number>>({});
    const [currencyPriceLoading, setCurrencyPriceLoading] = useState<Record<string, boolean>>({});
    const [savingCurrency, setSavingCurrency] = useState(false);

    useEffect(() => {
        void getBaseCurrencyCode().then((c) => {
            if (!c) return;
            setBaseCode(c);
            if (!editingCurrency) setEditingCurrency(c);
        });
    }, []);

    // Get unique categories
    const categories = useMemo(() => {
        const activeKeys = categoryDefs.filter(c => c.isActive).map(c => c.key);
        const usedKeys = [...new Set(menuItems.map((item: MenuItem) => item.category))].filter(Boolean);
        const merged = Array.from(new Set([...activeKeys, ...usedKeys])).sort((a, b) => a.localeCompare(b));
        return ['all', ...merged];
    }, [categoryDefs, menuItems]);

    // Filter items
    const filteredItems = useMemo(() => {
        return menuItems.filter((item: MenuItem) => {
            const itemName = item.name['ar'] || '';
            const matchesSearch = itemName.toLowerCase().includes(searchTerm.toLowerCase());
            const matchesCategory = selectedCategory === 'all' || item.category === selectedCategory;
            const matchesGroup = selectedGroup === 'all' || String((item as any).group || '') === selectedGroup;
            return matchesSearch && matchesCategory && matchesGroup && item.status === 'active';
        });
    }, [menuItems, searchTerm, selectedCategory, selectedGroup]);

    const handleUpdatePrice = async (itemId: string) => {
        const price = parseFloat(newPrice);
        if (!(price > 0)) return;
        if (!reason.trim()) {
            showNotification('سبب تعديل السعر مطلوب.', 'error');
            return;
        }
        try {
            const currency = String(editingCurrency || baseCode || '').toUpperCase();
            const base = String(baseCode || '').toUpperCase();
            if (!currency || currency === base) {
                await updatePrice(itemId, price, reason);
            } else {
                const supabase = getSupabaseClient();
                if (!supabase) throw new Error('قاعدة البيانات غير متاحة');
                setSavingCurrency(true);
                const { error } = await supabase.rpc('upsert_item_currency_price_admin', {
                    p_item_id: itemId,
                    p_currency_code: currency,
                    p_price_value: price,
                    p_effective_from: new Date().toISOString().slice(0, 10),
                } as any);
                if (error) throw error;
                setCurrencyPriceMap((prev) => ({ ...prev, [`${itemId}:${currency}`]: price }));
            }
            setSelectedItem(null);
            setNewPrice('');
            setEditingCurrency(baseCode);
            setReason('');
            showNotification('تم تحديث السعر', 'success');
        } catch (error) {
            const message = localizeSupabaseError(error) || 'فشل تحديث السعر';
            showNotification(message, 'error');
        } finally {
            setSavingCurrency(false);
        }
    };

    const loadCurrencyPrice = async (itemId: string, currency: string, basePrice?: number) => {
        const cur = String(currency || '').trim().toUpperCase();
        if (!cur) return;
        const key = `${itemId}:${cur}`;
        if (currencyPriceMap[key] != null) return;
        if (currencyPriceLoading[key]) return;
        setCurrencyPriceLoading((prev) => ({ ...prev, [key]: true }));
        try {
            const supabase = getSupabaseClient();
            if (!supabase) throw new Error('قاعدة البيانات غير متاحة');
            const { data, error } = await supabase
                .from('product_prices_multi_currency')
                .select('price_value,pricing_method,is_active,effective_from,updated_at')
                .eq('item_id', itemId)
                .eq('currency_code', cur)
                .eq('is_active', true)
                .order('effective_from', { ascending: false })
                .order('updated_at', { ascending: false })
                .limit(1)
                .maybeSingle();
            if (!error && data && typeof (data as any).price_value !== 'undefined') {
                const v = Number((data as any).price_value);
                if (Number.isFinite(v)) {
                    setCurrencyPriceMap((prev) => ({ ...prev, [key]: v }));
                    return;
                }
            }
            if (cur === 'YER' && typeof basePrice === 'number' && basePrice > 0) {
                const fx = await getOperationalFxRate('YER');
                if (fx && fx > 0) {
                    const suggested = Number((basePrice / fx).toFixed(2));
                    setCurrencyPriceMap((prev) => ({ ...prev, [key]: suggested }));
                }
            }
        } catch {
        } finally {
            setCurrencyPriceLoading((prev) => ({ ...prev, [key]: false }));
        }
    };

    useEffect(() => {
        const base = String(baseCode || '').toUpperCase();
        const cur = String(editingCurrency || '').toUpperCase();
        if (!base || cur !== 'YER') return;
        const targets = filteredItems.slice(0, 50);
        for (const it of targets) {
            const basePrice = Number((it as any)?.price || 0);
            void loadCurrencyPrice(String(it.id), 'YER', basePrice);
        }
    }, [baseCode, editingCurrency, filteredItems]);

    return (
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
            <div className="mb-8">
                <h1 className="text-3xl font-bold text-gray-900 dark:text-white mb-2">
                    إدارة الأسعار
                </h1>
                <p className="text-gray-600 dark:text-gray-400">
                    تحديث أسعار المنتجات وعرض تاريخ التغييرات
                </p>
            </div>

            {/* Filters */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-md p-6 mb-6">
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                    <div className="md:col-span-3 flex items-center gap-3">
                        <div className="text-sm font-semibold text-gray-700 dark:text-gray-300">عملة تحرير الأسعار</div>
                        <select
                            value={editingCurrency || baseCode}
                            onChange={(e) => setEditingCurrency(String(e.target.value || '').trim().toUpperCase())}
                            className="px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                        >
                            <option value={baseCode}>{baseCode}</option>
                            <option value="YER">YER</option>
                        </select>
                        <div className="text-xs text-gray-500 dark:text-gray-400">
                            السعر الأساسي يُدار بالعملة الأساسية. لتثبيت سعر YER بدون التأثر بـ FX، اختر YER وحدّث السعر.
                        </div>
                    </div>
                    <div>
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                            البحث
                        </label>
                        <input
                            type="text"
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            placeholder="ابحث عن منتج..."
                            className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-gold-500"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                            الفئة
                        </label>
                        <select
                            value={selectedCategory}
                            onChange={(e) => setSelectedCategory(e.target.value)}
                            className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-gold-500"
                        >
                            <option value="all">الكل</option>
                            {categories.filter(c => c !== 'all').map((cat: string) => (
                                <option key={cat} value={cat}>{getCategoryLabel(cat, 'ar')}</option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                            المجموعة
                        </label>
                        <select
                            value={selectedGroup}
                            onChange={(e) => setSelectedGroup(e.target.value)}
                            className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-gold-500"
                        >
                            <option value="all">الكل</option>
                            {[...new Set(menuItems
                                .filter((it: any) => selectedCategory === 'all' || String(it?.category || '') === selectedCategory)
                                .map((it: any) => String(it?.group || ''))
                                .filter(Boolean))]
                                .map((g: string) => (
                                    <option key={g} value={g}>{getGroupLabel(g, selectedCategory !== 'all' ? selectedCategory : undefined, 'ar')}</option>
                                ))}
                        </select>
                    </div>
                </div>
            </div>

            {/* Prices Table */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden">
                <div className="overflow-x-auto">
                    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                        <thead className="bg-gray-50 dark:bg-gray-900">
                            <tr>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    المنتج
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    السعر الأساسي
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    الوحدة
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    آخر تحديث
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    إجراءات
                                </th>
                            </tr>
                        </thead>
                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {filteredItems.map((item: MenuItem) => {
                                const history = getPriceHistoryByItemId(item.id);
                                const lastUpdate = history[0];
                                const isEditing = selectedItem === item.id;
                                const itemName = item.name['ar'] || '';
                                const basePrice = Number(item.price || 0);

                                return (
                                    <React.Fragment key={item.id}>
                                        <tr>
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <div className="flex items-center">
                                                    <img src={item.imageUrl || undefined} alt={itemName} className="w-10 h-10 rounded-md object-cover" />
                                                    <div className="mr-4 rtl:mr-0 rtl:ml-4">
                                                        <div className="text-sm font-medium text-gray-900 dark:text-white">
                                                            {itemName}
                                                        </div>
                                                    </div>
                                                </div>
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <div className="space-y-1">
                                                    <span className="text-gold-600 dark:text-gold-400">
                                                        <CurrencyDualAmount amount={Number(item.price || 0)} currencyCode={baseCode} compact />
                                                    </span>
                                                    {String(editingCurrency || baseCode || '').toUpperCase() === 'YER' && (
                                                        <div className="text-[11px] text-gray-600 dark:text-gray-400" dir="ltr">
                                                            {(() => {
                                                                const key = `${item.id}:YER`;
                                                                const v = currencyPriceMap[key];
                                                                const loading = Boolean(currencyPriceLoading[key]);
                                                                if (loading) return 'YER: ...';
                                                                if (typeof v === 'number') {
                                                                    return `YER: ${Number(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
                                                                }
                                                                return 'YER: —';
                                                            })()}
                                                        </div>
                                                    )}
                                                </div>
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
                                                {getUnitLabel(item.unitType as any, 'ar')}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
                                                {lastUpdate ? new Date(lastUpdate.date).toLocaleDateString('ar-SA-u-nu-latn') : '-'}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <button
                                                    onClick={() => {
                                                        setSelectedItem(item.id);
                                                        const currency = String(editingCurrency || baseCode || '').toUpperCase();
                                                        if (currency && currency !== String(baseCode || '').toUpperCase()) {
                                                            void loadCurrencyPrice(item.id, currency, basePrice);
                                                            const v = currencyPriceMap[`${item.id}:${currency}`];
                                                            setNewPrice(String(typeof v === 'number' ? v : ''));
                                                        } else {
                                                            setNewPrice(item.price.toString());
                                                        }
                                                    }}
                                                    className="text-gold-600 hover:text-gold-800 dark:text-gold-400 dark:hover:text-gold-300 font-medium"
                                                >
                                                    {String(editingCurrency || baseCode || '').toUpperCase() === 'YER' ? 'تحديث سعر YER' : 'تحديث السعر'}
                                                </button>
                                                <div className="mt-1 text-[11px] text-gray-500 dark:text-gray-400">
                                                    {String(editingCurrency || baseCode || '').toUpperCase() === 'YER'
                                                        ? 'سعر YER مستقل ولن يتغير بتحرك FX.'
                                                        : `تغييرات هذا الجدول تخص السعر الأساسي (${String(baseCode || '').toUpperCase() || '—'}).`}
                                                </div>
                                            </td>
                                        </tr>
                                        {isEditing && (
                                            <tr className="bg-gold-50 dark:bg-gold-900/10">
                                                <td colSpan={5} className="px-6 py-4">
                                                    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                                                        <div>
                                                            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                                                                السعر الجديد ({String(editingCurrency || baseCode || '').toUpperCase()})
                                                            </label>
                                                            <input
                                                                type="number"
                                                                value={newPrice}
                                                                onChange={(e) => setNewPrice(e.target.value)}
                                                                className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                                                                step="0.01"
                                                                min="0"
                                                            />
                                                            {String(editingCurrency || baseCode || '').toUpperCase() === 'YER' && (
                                                                <div className="mt-2 text-[11px] text-gray-500 dark:text-gray-400">
                                                                    هذا السعر ثابت باليمني ولن يتغير بتحرك FX.
                                                                </div>
                                                            )}
                                                        </div>
                                                        <div>
                                                            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                                                                سبب التغيير
                                                            </label>
                                                            <input
                                                                type="text"
                                                                value={reason}
                                                                onChange={(e) => setReason(e.target.value)}
                                                                placeholder="مثال: ارتفاع الأسعار"
                                                                className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                                                            />
                                                        </div>
                                                        <div className="flex items-end gap-2">
                                                            <button
                                                                onClick={() => handleUpdatePrice(item.id)}
                                                                disabled={savingCurrency}
                                                                className="flex-1 bg-green-500 text-white px-4 py-2 rounded-lg hover:bg-green-600 transition disabled:opacity-60 disabled:cursor-not-allowed"
                                                            >
                                                                حفظ
                                                            </button>
                                                            <button
                                                                onClick={() => {
                                                                    setSelectedItem(null);
                                                                    setNewPrice('');
                                                                    setEditingCurrency(baseCode);
                                                                    setReason('');
                                                                }}
                                                                className="flex-1 bg-gray-500 text-white px-4 py-2 rounded-lg hover:bg-gray-600 transition"
                                                            >
                                                                إلغاء
                                                            </button>
                                                        </div>
                                                    </div>
                                                    {history.length > 0 && (
                                                        <div className="mt-4">
                                                            <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                                                                تاريخ تغييرات السعر الأساسي
                                                            </h4>
                                                            <div className="space-y-2">
                                                                {history.slice(0, 5).map((h: PriceHistory) => (
                                                                    <div key={h.id} className="flex items-center justify-between text-sm bg-white dark:bg-gray-800 p-2 rounded">
                                                                        <span className="text-gray-600 dark:text-gray-400">
                                                                            {new Date(h.date).toLocaleString('ar-SA-u-nu-latn')}
                                                                        </span>
                                                                        <span className="text-gray-900 dark:text-white">
                                                                            <CurrencyDualAmount amount={Number(h.price || 0)} currencyCode={baseCode} compact />
                                                                        </span>
                                                                        {h.reason && (
                                                                            <span className="text-gray-500 dark:text-gray-400 italic">
                                                                                {h.reason}
                                                                            </span>
                                                                        )}
                                                                    </div>
                                                                ))}
                                                            </div>
                                                        </div>
                                                    )}
                                                    {String(editingCurrency || baseCode || '').toUpperCase() === 'YER' && (
                                                        <div className="mt-3 text-[11px] text-gray-500 dark:text-gray-400">
                                                            تغييرات سعر YER تُسجل كسعر مستقل ضمن التسعير متعدد العملات.
                                                        </div>
                                                    )}
                                                </td>
                                            </tr>
                                        )}
                                    </React.Fragment>
                                );
                            })}
                        </tbody>
                    </table>
                </div>

                {filteredItems.length === 0 && (
                    <div className="text-center py-12">
                        <p className="text-gray-500 dark:text-gray-400">
                            لا توجد منتجات
                        </p>
                    </div>
                )}
            </div>
        </div>
    );
};

export default ManagePricesScreen;
