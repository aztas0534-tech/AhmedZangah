import React, { useState, useEffect } from 'react';
import { useAuth } from '../../contexts/AuthContext';
import { useWarehouses } from '../../contexts/WarehouseContext';
import { useToast } from '../../contexts/ToastContext';
import { getSupabaseClient } from '../../supabase';
import type { InventoryCount, InventoryCountItem } from '../../types';
import * as Icons from '../../components/icons';
import { toYmdLocal } from '../../utils/dateUtils';

const StocktakingScreen: React.FC = () => {
    const { user, hasPermission } = useAuth();
    const { warehouses } = useWarehouses();
    const { showNotification } = useToast();

    const [loading, setLoading] = useState(false);
    const [counts, setCounts] = useState<InventoryCount[]>([]);
    const [selectedCount, setSelectedCount] = useState<InventoryCount | null>(null);
    const [countItems, setCountItems] = useState<InventoryCountItem[]>([]);
    const [showCreateModal, setShowCreateModal] = useState(false);

    // Filters
    const [warehouseId, setWarehouseId] = useState('');

    // form state
    const [formWarehouseId, setFormWarehouseId] = useState('');
    const [formNotes, setFormNotes] = useState('');

    const canManage = hasPermission('stock.manage') || user?.role === 'owner' || user?.role === 'manager';

    const fetchCounts = async () => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        setLoading(true);
        try {
            let query = supabase
                .from('inventory_counts')
                .select(`
          id, warehouse_id, status, created_by, started_at, completed_at, notes, created_at, updated_at,
          warehouses (name),
          auth_users:created_by (raw_user_meta_data)
        `)
                .order('created_at', { ascending: false });

            if (warehouseId) query = query.eq('warehouse_id', warehouseId);

            const { data, error } = await query;
            if (error) throw error;

            const mapped = (data || []).map((row: any) => ({
                id: row.id,
                warehouseId: row.warehouse_id,
                warehouseName: row.warehouses?.name || '',
                status: row.status,
                createdBy: row.created_by,
                createdByName: row.auth_users?.raw_user_meta_data?.name || row.created_by,
                startedAt: row.started_at,
                completedAt: row.completed_at,
                notes: row.notes,
                createdAt: row.created_at,
                updatedAt: row.updated_at,
            } as InventoryCount));

            setCounts(mapped);
        } catch (err: any) {
            showNotification(err.message || 'فشل تحميل جلسات الجرد', 'error');
        } finally {
            setLoading(false);
        }
    };

    useEffect(() => {
        void fetchCounts();
    }, [warehouseId]);

    const loadCountItems = async (countId: string) => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        try {
            const { data, error } = await supabase
                .from('inventory_count_items')
                .select(`
          id, count_id, item_id, expected_quantity, actual_quantity, variance, unit_cost, notes,
          menu_items (name, category, data)
        `)
                .eq('count_id', countId)
                .order('item_id', { ascending: true });

            if (error) throw error;

            const mapped = (data || []).map((row: any) => ({
                id: row.id,
                countId: row.count_id,
                itemId: row.item_id,
                itemName: row.menu_items?.name?.ar || row.menu_items?.name?.en || row.item_id,
                expectedQuantity: Number(row.expected_quantity || 0),
                actualQuantity: row.actual_quantity !== null ? Number(row.actual_quantity) : null,
                variance: row.variance !== null ? Number(row.variance) : null,
                unitCost: row.unit_cost !== null ? Number(row.unit_cost) : null,
                notes: row.notes,
            } as InventoryCountItem));

            setCountItems(mapped);
        } catch (err: any) {
            showNotification('فشل تحميل عناصر الجرد', 'error');
        }
    };

    const handleSelectCount = (count: InventoryCount) => {
        setSelectedCount(count);
        if (count.status === 'in_progress' || count.status === 'completed') {
            void loadCountItems(count.id);
        } else {
            setCountItems([]);
        }
    };

    const handleCreateCount = async (e: React.FormEvent) => {
        e.preventDefault();
        if (!formWarehouseId) {
            showNotification('يرجى اختيار المستودع', 'error');
            return;
        }
        const supabase = getSupabaseClient();
        if (!supabase) return;

        try {
            const { data, error } = await supabase
                .from('inventory_counts')
                .insert({
                    warehouse_id: formWarehouseId,
                    notes: formNotes,
                    created_by: user?.id,
                    status: 'draft'
                })
                .select()
                .single();

            if (error) throw error;

            showNotification('تم إنشاء جلسة الجرد بنجاح', 'success');
            setShowCreateModal(false);
            setFormWarehouseId('');
            setFormNotes('');
            await fetchCounts();

            if (data) {
                handleSelectCount({
                    id: data.id,
                    warehouseId: data.warehouse_id,
                    status: data.status,
                    createdBy: data.created_by,
                    notes: data.notes,
                    createdAt: data.created_at,
                    updatedAt: data.updated_at
                } as InventoryCount);
            }
        } catch (err: any) {
            showNotification(err.message || 'حدث خطأ', 'error');
        }
    };

    const handleStartCount = async (countId: string) => {
        if (!confirm('هل أنت متأكد من بدء جلسة الجرد؟ سيتم تثبيت رصيد النظام الحالي للأصناف.')) return;
        const supabase = getSupabaseClient();
        if (!supabase) return;
        try {
            const { error } = await supabase.rpc('start_inventory_count', { p_count_id: countId } as any);
            if (error) throw error;
            showNotification('تم بدء الجرد بنجاح', 'success');
            await fetchCounts();
            if (selectedCount?.id === countId) {
                setSelectedCount({ ...selectedCount, status: 'in_progress', startedAt: new Date().toISOString() });
                void loadCountItems(countId);
            }
        } catch (err: any) {
            showNotification(err.message || 'فشل بدء الجرد', 'error');
        }
    };

    const handleCompleteCount = async (countId: string) => {
        if (!confirm('هل أنت متأكد من إنهاء جلسة الجرد والاعتماد؟ سيتم توليد حركات تسوية مخزنية للفروقات وتسجيلها في النظام.')) return;

        // Check if any nulls left
        const hasNulls = countItems.some(i => i.actualQuantity === null);
        if (hasNulls && !confirm('يوجد أصناف لم يتم إدخال الجرد الفعلي لها (ستحتسب فروقات بالكامل). هل ترغب بالاستمرار حقاً؟')) {
            return;
        }

        const supabase = getSupabaseClient();
        if (!supabase) return;
        try {
            const { error } = await supabase.rpc('complete_inventory_count', { p_count_id: countId } as any);
            if (error) throw error;
            showNotification('تم إنهاء الجرد واعتماد الفروقات بنجاح', 'success');
            await fetchCounts();
            if (selectedCount?.id === countId) {
                setSelectedCount({ ...selectedCount, status: 'completed', completedAt: new Date().toISOString() });
                void loadCountItems(countId);
            }
        } catch (err: any) {
            showNotification(err.message || 'فشل إعتماد الجرد', 'error');
        }
    };

    const handleSaveActualQuantity = async (itemId: string, val: string) => {
        if (!selectedCount || selectedCount.status !== 'in_progress') return;

        const n = val.trim() === '' ? null : Number(val);
        if (n !== null && isNaN(n)) return;

        setCountItems(prev => prev.map(it => {
            if (it.itemId === itemId) {
                return {
                    ...it,
                    actualQuantity: n,
                    variance: n !== null ? n - it.expectedQuantity : null
                };
            }
            return it;
        }));

        const supabase = getSupabaseClient();
        if (!supabase) return;

        // Optional: auto-save immediately to DB
        const currentItem = countItems.find(i => i.itemId === itemId);
        if (!currentItem) return;

        try {
            await supabase
                .from('inventory_count_items')
                .update({
                    actual_quantity: n,
                    variance: n !== null ? n - currentItem.expectedQuantity : null
                })
                .eq('count_id', selectedCount.id)
                .eq('item_id', itemId);
        } catch (err) {
            console.error('Failed to autosave actual quantity', err);
        }
    };

    const renderStatusBadge = (status: string) => {
        switch (status) {
            case 'draft': return <span className="px-2 py-1 text-xs font-semibold rounded-full bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300">مسودة</span>;
            case 'in_progress': return <span className="px-2 py-1 text-xs font-semibold rounded-full bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300">قيد الجرد</span>;
            case 'completed': return <span className="px-2 py-1 text-xs font-semibold rounded-full bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300">مكتمل ومرحل</span>;
            case 'cancelled': return <span className="px-2 py-1 text-xs font-semibold rounded-full bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300">ملغى</span>;
            default: return <span>{status}</span>;
        }
    };

    return (
        <div className="p-6 max-w-7xl mx-auto space-y-6">
            <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
                <div>
                    <h1 className="text-3xl font-bold bg-clip-text text-transparent bg-gradient-to-l from-primary-600 to-gold-500">
                        جلسات الجرد للمخزون
                    </h1>
                    <p className="text-gray-500 dark:text-gray-400 mt-2">
                        إدارة جولات الجرد ومطابقة المخزون الفعلي مع النظام
                    </p>
                </div>

                {canManage && (
                    <button
                        onClick={() => setShowCreateModal(true)}
                        className="px-4 py-2 bg-gradient-to-r from-primary-600 to-gold-500 text-white rounded-lg hover:from-primary-700 hover:to-gold-600 font-semibold flex items-center gap-2 shadow-lg"
                    >
                        <Icons.Plus className="w-5 h-5" />
                        جلسة جرد جديدة
                    </button>
                )}
            </div>

            <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">

                {/* Sidebar for Sessions List */}
                <div className="col-span-1 border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 rounded-xl shadow-sm flex flex-col h-[calc(100vh-200px)]">
                    <div className="p-4 border-b border-gray-100 dark:border-gray-700">
                        <h2 className="font-semibold text-gray-800 dark:text-gray-200 mb-3">الجلسات المتاحة</h2>

                        <select
                            value={warehouseId}
                            onChange={(e) => setWarehouseId(e.target.value)}
                            className="w-full px-3 py-2 bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-700 rounded-lg text-sm"
                        >
                            <option value="">كل المستودعات</option>
                            {warehouses.map((w: any) => (
                                <option key={w.id} value={w.id}>{w.name}</option>
                            ))}
                        </select>
                    </div>

                    <div className="flex-1 overflow-y-auto p-2 space-y-2">
                        {loading ? (
                            <p className="text-center text-gray-500 text-sm py-4">جاري التحميل...</p>
                        ) : counts.length === 0 ? (
                            <p className="text-center text-gray-500 text-sm py-4">لا توجد جلسات جرد</p>
                        ) : (
                            counts.map(count => (
                                <button
                                    key={count.id}
                                    onClick={() => handleSelectCount(count)}
                                    className={`w-full text-right p-3 rounded-lg border text-sm transition-all ${selectedCount?.id === count.id
                                        ? 'border-primary-500 bg-primary-50 dark:bg-primary-900/20'
                                        : 'border-transparent hover:bg-gray-50 dark:hover:bg-gray-700'
                                        }`}
                                >
                                    <div className="flex justify-between items-start mb-2">
                                        <span className="font-semibold text-gray-800 dark:text-gray-200">{count.warehouseName}</span>
                                        {renderStatusBadge(count.status)}
                                    </div>
                                    <div className="text-xs text-gray-500 flex flex-col gap-1">
                                        <span>{toYmdLocal(new Date(count.createdAt))}</span>
                                        <span className="truncate">بواسطة: {count.createdByName}</span>
                                    </div>
                                </button>
                            ))
                        )}
                    </div>
                </div>

                {/* Main Panel for Selected Session */}
                <div className="col-span-1 lg:col-span-3">
                    {selectedCount ? (
                        <div className="border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 rounded-xl shadow-sm flex flex-col h-[calc(100vh-200px)]">
                            {/* Header */}
                            <div className="p-6 border-b border-gray-100 dark:border-gray-700 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 bg-gray-50 dark:bg-gray-900/50 rounded-t-xl">
                                <div>
                                    <h2 className="text-xl font-bold flex items-center gap-3">
                                        مستودع: {selectedCount.warehouseName}
                                        {renderStatusBadge(selectedCount.status)}
                                    </h2>
                                    <div className="text-sm text-gray-500 mt-2 flex gap-4">
                                        <span>تاريخ: {toYmdLocal(new Date(selectedCount.createdAt))}</span>
                                        {selectedCount.startedAt && <span>انطلق: {new Date(selectedCount.startedAt).toLocaleString('ar-EG-u-nu-latn')}</span>}
                                    </div>
                                </div>

                                <div className="flex gap-2">
                                    {selectedCount.status === 'draft' && canManage && (
                                        <button
                                            onClick={() => handleStartCount(selectedCount.id)}
                                            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-semibold shadow flex items-center gap-2"
                                        >
                                            <Icons.RotateCwIcon className="w-5 h-5" /> بدء الجرد الفعلي
                                        </button>
                                    )}
                                    {selectedCount.status === 'in_progress' && canManage && (
                                        <button
                                            onClick={() => handleCompleteCount(selectedCount.id)}
                                            className="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg font-semibold shadow flex items-center gap-2"
                                        >
                                            <Icons.Check className="w-5 h-5" /> إعتماد النواقص والتسوية
                                        </button>
                                    )}
                                </div>
                            </div>

                            {/* Items Table */}
                            <div className="flex-1 overflow-auto">
                                {selectedCount.status === 'draft' ? (
                                    <div className="flex items-center justify-center h-full text-gray-500 dark:text-gray-400">
                                        <p className="text-center">انقر على الزر بالأعلى لبدء الجرد الفعلي وسحب أرصدة النظام الحالية.</p>
                                    </div>
                                ) : (
                                    <table className="w-full text-right">
                                        <thead className="bg-white dark:bg-gray-800 sticky top-0 z-10 shadow-sm">
                                            <tr className="border-b border-gray-200 dark:border-gray-700">
                                                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-400">الصنف</th>
                                                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-400">الكمية دفترياً (تلقائي)</th>
                                                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-400">الكمية الفعلية</th>
                                                <th className="p-3 text-sm font-semibold text-gray-600 dark:text-gray-400">الفارق</th>
                                            </tr>
                                        </thead>
                                        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                                            {countItems.map((item) => (
                                                <tr key={item.itemId} className="hover:bg-gray-50 dark:hover:bg-gray-700/30 transition">
                                                    <td className="p-3">
                                                        <span className="font-semibold block">{item.itemName}</span>
                                                        <span className="text-xs text-gray-500 font-mono">{item.itemId}</span>
                                                    </td>
                                                    <td className="p-3 font-mono text-gray-700 dark:text-gray-300" dir="ltr">
                                                        {Number(item.expectedQuantity).toFixed(2)}
                                                    </td>
                                                    <td className="p-3">
                                                        {selectedCount.status === 'in_progress' ? (
                                                            <input
                                                                type="number"
                                                                step="any"
                                                                value={item.actualQuantity === null ? '' : item.actualQuantity}
                                                                onChange={(e) => handleSaveActualQuantity(item.itemId, e.target.value)}
                                                                className={`w-32 px-3 py-1.5 border rounded-lg font-mono text-left focus:ring-2 disabled:bg-gray-100 dark:disabled:bg-gray-800 ${item.actualQuantity === null
                                                                    ? 'border-red-300 dark:border-red-700 bg-red-50 dark:bg-red-900/10'
                                                                    : 'border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700'
                                                                    }`}
                                                                placeholder="الفعلية"
                                                            />
                                                        ) : (
                                                            <span className="font-mono text-gray-900 dark:text-gray-100" dir="ltr">
                                                                {item.actualQuantity === null ? '—' : Number(item.actualQuantity).toFixed(2)}
                                                            </span>
                                                        )}
                                                    </td>
                                                    <td className="p-3">
                                                        <span className={`font-mono font-semibold text-sm ${item.variance === null ? 'text-gray-400' :
                                                            item.variance === 0 ? 'text-green-600' :
                                                                item.variance > 0 ? 'text-blue-600' : 'text-red-600'
                                                            }`} dir="ltr">
                                                            {item.variance === null ? '—' : item.variance === 0 ? 'مطابق' : (item.variance > 0 ? `+${item.variance.toFixed(2)} زيادة` : `${item.variance.toFixed(2)} عجز`)}
                                                        </span>
                                                    </td>
                                                </tr>
                                            ))}
                                            {countItems.length === 0 && (
                                                <tr>
                                                    <td colSpan={4} className="p-8 text-center text-gray-500">لا توجد أصناف في هذا الجرد</td>
                                                </tr>
                                            )}
                                        </tbody>
                                    </table>
                                )}
                            </div>
                        </div>
                    ) : (
                        <div className="border border-gray-200 dark:border-gray-700 border-dashed bg-gray-50 dark:bg-gray-800/30 rounded-xl flex items-center justify-center text-gray-500 dark:text-gray-400 h-[calc(100vh-200px)]">
                            اختر جلسة جرد من القائمة الجانبية أو قم بإنشاء جلسة جديدة
                        </div>
                    )}
                </div>
            </div>

            {/* Create Modal */}
            {showCreateModal && (
                <div className="fixed inset-0 bg-black/50 z-50 flex items-center justify-center p-4">
                    <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-md overflow-hidden">
                        <div className="p-5 border-b border-gray-200 dark:border-gray-700 flex justify-between items-center">
                            <h3 className="font-bold text-lg dark:text-white">إطلاق جلسة جرد لفرع</h3>
                            <button onClick={() => setShowCreateModal(false)} className="text-gray-500 hover:text-gray-700 dark:hover:text-gray-300">
                                <Icons.X className="w-5 h-5" />
                            </button>
                        </div>

                        <form onSubmit={handleCreateCount} className="p-5 space-y-4">
                            <div>
                                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">المستودع المطلوب جرده *</label>
                                <select
                                    required
                                    value={formWarehouseId}
                                    onChange={(e) => setFormWarehouseId(e.target.value)}
                                    className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                                >
                                    <option value="">-- إختر المستودع --</option>
                                    {warehouses.map(w => (
                                        <option key={w.id} value={w.id}>{w.name}</option>
                                    ))}
                                </select>
                            </div>

                            <div>
                                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">ملاحظات / سبب الجرد</label>
                                <textarea
                                    value={formNotes}
                                    onChange={(e) => setFormNotes(e.target.value)}
                                    className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                                    rows={3}
                                    placeholder="مثال: جرد نهاية العام"
                                />
                            </div>

                            <div className="pt-4 flex gap-3">
                                <button
                                    type="submit"
                                    className="flex-1 px-4 py-2 bg-gradient-to-r from-primary-600 to-gold-500 text-white rounded-lg hover:from-primary-700 hover:to-gold-600 text-sm font-semibold"
                                >
                                    إنشاء
                                </button>
                                <button
                                    type="button"
                                    onClick={() => setShowCreateModal(false)}
                                    className="flex-1 px-4 py-2 bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200 rounded-lg text-sm font-semibold hover:bg-gray-200 dark:hover:bg-gray-600"
                                >
                                    إلغاء
                                </button>
                            </div>
                        </form>
                    </div>
                </div>
            )}
        </div>
    );
};

export default StocktakingScreen;
