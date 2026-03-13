import React, { useState, useMemo, useEffect } from 'react';
import { useMenu } from '../../contexts/MenuContext';
import { useStock } from '../../contexts/StockContext';
// import { useSettings } from '../../contexts/SettingsContext';
import type { MenuItem, StockHistory, UnitType, StockManagement, ItemBatch } from '../../types';
import { useItemMeta } from '../../contexts/ItemMetaContext';
import { MinusIcon, PlusIcon } from '../../components/icons';
import { useToast } from '../../contexts/ToastContext';
import { useAuth } from '../../contexts/AuthContext';
import { getBaseCurrencyCode, getSupabaseClient } from '../../supabase';
import { useSessionScope } from '../../contexts/SessionScopeContext';
import { useWarehouses } from '../../contexts/WarehouseContext';
import { localizeSupabaseError } from '../../utils/errorUtils';

import RecordWastageModal from '../../components/admin/RecordWastageModal';
import BatchLabel from '../../components/admin/documents/BatchLabel';
import { renderToString } from 'react-dom/server';
import { printContent } from '../../utils/printUtils';

type StockRowProps = {
    item: MenuItem;
    stock: StockManagement | undefined;
    warehouseId: string;
    readOnlyMode: boolean;
    baseCode: string;
    getCategoryLabel: (categoryKey: string, language: 'ar' | 'en') => string;
    getUnitLabel: (unitKey: UnitType | undefined, language: 'ar' | 'en') => string;
    handleUpdateStock: (itemId: string, newQuantity: number, unit: string, batchId?: string, minStock?: number) => Promise<void>;
    toggleHistory: (itemId: string) => Promise<void>;
    expandedHistoryItemId: string | null;
    historyLoadingItemId: string | null;
    historyByItemId: Record<string, StockHistory[]>;
    setIsWastageModalOpen: (open: boolean) => void;
    setWastageItem: (item: MenuItem | null) => void;
};

const StockRow = ({ item, stock, warehouseId, readOnlyMode, baseCode, getCategoryLabel, getUnitLabel, handleUpdateStock, toggleHistory, expandedHistoryItemId, historyLoadingItemId, historyByItemId, setIsWastageModalOpen, setWastageItem }: StockRowProps) => {
    const { hasPermission } = useAuth();
    const { showNotification } = useToast();
    const currentStock = Number(stock?.availableQuantity ?? 0);
    const qcHold = Number(stock?.qcHoldQuantity ?? 0);
    const reserved = Number(stock?.reservedQuantity ?? 0);
    const available = currentStock - reserved;
    const unit = String(stock?.unit ?? item.unitType ?? 'piece');
    const threshold = Number(stock?.minimumStockLevel ?? stock?.lowStockThreshold ?? 5);
    const isLowStock = available <= threshold;
    const itemName = item.name?.['ar'] || item.name?.en || '';

    const [localStock, setLocalStock] = useState<string>(String(currentStock));
    const [localMinStock, setLocalMinStock] = useState<string>(String(stock?.minimumStockLevel ?? ''));
    const [batches, setBatches] = useState<ItemBatch[]>([]);
    const [selectedBatchId, setSelectedBatchId] = useState<string>('');
    const canQc = hasPermission('qc.inspect') || hasPermission('qc.release');
    const [showBatches, setShowBatches] = useState<boolean>(canQc);
    const [qcBusyBatchId, setQcBusyBatchId] = useState<string | null>(null);
    const canRepairCost = hasPermission('accounting.manage');
    const [repairCostBusy, setRepairCostBusy] = useState(false);
    const [revalueBatchBusy, setRevalueBatchBusy] = useState(false);
    const [editingDatesBatchId, setEditingDatesBatchId] = useState<string | null>(null);
    const [editProdDate, setEditProdDate] = useState('');
    const [editExpDate, setEditExpDate] = useState('');
    const [dateSaveBusy, setDateSaveBusy] = useState(false);
    const getErrorMessage = (error: unknown, fallback: string) => {
        if (error instanceof Error && error.message) return error.message;
        const msg = String((error as any)?.message || '');
        return msg || fallback;
    };

    useEffect(() => {
        setLocalStock(String(currentStock));
    }, [currentStock]);

    useEffect(() => {
        setLocalMinStock(String(stock?.minimumStockLevel ?? ''));
    }, [stock?.minimumStockLevel]);

    useEffect(() => {
        if (canQc || qcHold > 0) {
            setShowBatches(true);
        }
    }, [canQc, qcHold]);

    const loadBatchesDetailed = async () => {
        try {
            const supabase = getSupabaseClient();
            if (!supabase) return;
            const { data, error } = await supabase.rpc('get_item_batches', { p_item_id: item.id, p_warehouse_id: warehouseId || null } as any);
            if (error) return;
            const rows = (data || []) as any[];
            const batchIds = rows.map((r: any) => String(r.batch_id || '')).filter(Boolean);
            const movementMap: Record<string, { sale: number; ret: number; wastage: number; adjust: number }> = {};
            if (batchIds.length > 0) {
                const { data: mvRows } = await supabase
                    .from('inventory_movements')
                    .select('batch_id,movement_type,quantity')
                    .in('batch_id', batchIds as any)
                    .in('movement_type', ['sale_out', 'return_out', 'wastage_out', 'adjust_out']);
                for (const m of (mvRows || []) as any[]) {
                    const bid = String((m as any)?.batch_id || '');
                    if (!bid) continue;
                    if (!movementMap[bid]) movementMap[bid] = { sale: 0, ret: 0, wastage: 0, adjust: 0 };
                    const qty = Number((m as any)?.quantity || 0) || 0;
                    const t = String((m as any)?.movement_type || '');
                    if (t === 'sale_out') movementMap[bid].sale += qty;
                    if (t === 'return_out') movementMap[bid].ret += qty;
                    if (t === 'wastage_out') movementMap[bid].wastage += qty;
                    if (t === 'adjust_out') movementMap[bid].adjust += qty;
                }
            }
            const mapped = rows.map(r => {
                const bid = String(r.batch_id || '');
                const mv = movementMap[bid] || { sale: 0, ret: 0, wastage: 0, adjust: 0 };
                return {
                    batchId: r.batch_id,
                    occurredAt: r.occurred_at,
                    unitCost: Number(r.unit_cost) || 0,
                    unitCostOriginal: ((): number | undefined => {
                        const c = Number((r as any)?.unit_cost_original);
                        return Number.isFinite(c) && c > 0 ? c : undefined;
                    })(),
                    unitCostCurrency: ((): string | undefined => {
                        const cur = String(((r as any)?.currency) || '').trim().toUpperCase();
                        return cur || undefined;
                    })(),
                    fxAtReceipt: ((): number | undefined => {
                        const fx = Number((r as any)?.fx_rate_at_receipt);
                        return Number.isFinite(fx) && fx > 0 ? fx : undefined;
                    })(),
                    receivedQuantity: Number(r.received_quantity) || 0,
                    consumedQuantity: Number(r.consumed_quantity) || 0,
                    remainingQuantity: Number(r.remaining_quantity) || 0,
                    returnedQuantity: Number(mv.ret || 0),
                    soldQuantity: Number(mv.sale || 0),
                    wastageQuantity: Number(mv.wastage || 0),
                    adjustOutQuantity: Number(mv.adjust || 0),
                    qcStatus: String(r.qc_status || ''),
                    lastQcResult: (r.last_qc_result === 'pass' || r.last_qc_result === 'fail') ? r.last_qc_result : undefined,
                    lastQcAt: r.last_qc_at ? String(r.last_qc_at) : undefined,
                    productionDate: r.production_date ? String(r.production_date) : undefined,
                    expiryDate: r.expiry_date ? String(r.expiry_date) : undefined,
                };
            }) as ItemBatch[];
            setBatches(mapped);
        } catch (_) {
        }
    };

    useEffect(() => {
        if (readOnlyMode) {
            setBatches([]);
            return;
        }
        loadBatchesDetailed();
    }, [item.id, warehouseId, readOnlyMode]);

    const qcStatusLabel = (s: string) => {
        const v = String(s || '').trim();
        if (v === 'released') return 'مُفرج';
        if (v === 'inspected') return 'مفحوص';
        if (v === 'pending' || v === 'quarantined') return 'معلّق';
        return v || 'غير محدد';
    };

    const refreshBatches = async () => {
        await loadBatchesDetailed();
    };

    const runQcInspect = async (batchId: string, result: 'pass' | 'fail') => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        setQcBusyBatchId(batchId);
        try {
            const { error } = await supabase.rpc('qc_inspect_batch', { p_batch_id: batchId, p_result: result, p_notes: null } as any);
            if (error) throw error;
            showNotification(result === 'pass' ? 'تم تسجيل فحص QC (نجح).' : 'تم تسجيل فحص QC (فشل).', 'success');
        } catch (e) {
            const msg = e instanceof Error ? e.message : '';
            showNotification(msg && /[\u0600-\u06FF]/.test(msg) ? msg : 'فشل تنفيذ فحص QC.', 'error');
        } finally {
            setQcBusyBatchId(null);
            await refreshBatches();
        }
    };

    const runQcRelease = async (batchId: string) => {
        const supabase = getSupabaseClient();
        if (!supabase) return;
        setQcBusyBatchId(batchId);
        try {
            const { error } = await supabase.rpc('qc_release_batch', { p_batch_id: batchId } as any);
            if (error) throw error;
            showNotification('تم إفراج الدُفعة بنجاح.', 'success');
        } catch (e) {
            const msg = e instanceof Error ? e.message : '';
            showNotification(msg && /[\u0600-\u06FF]/.test(msg) ? msg : 'فشل إفراج الدُفعة.', 'error');
        } finally {
            setQcBusyBatchId(null);
            await refreshBatches();
        }
    };

    const repairItemCost = async () => {
        if (!canRepairCost) return;
        if (repairCostBusy) return;
        const supabase = getSupabaseClient();
        if (!supabase) {
            showNotification('قاعدة البيانات غير متاحة.', 'error');
            return;
        }
        const ok = window.confirm(`سيتم محاولة إصلاح تكلفة هذا الصنف بناءً على أوامر الشراء وسندات الاستلام والدفعات.\nالصنف: ${itemName || item.id}\nهل تريد المتابعة؟`);
        if (!ok) return;
        setRepairCostBusy(true);
        try {
            const dry = await supabase.rpc('repair_item_purchase_costs', { p_item_id: item.id, p_warehouse_id: warehouseId || null, p_dry_run: true } as any);
            if ((dry as any)?.error) throw (dry as any).error;
            const d: any = (dry as any)?.data || {};
            const ok2 = window.confirm(`نتيجة الفحص:\nسندات تحتاج تعديل=${Number(d?.receiptItemsNeedingFix || 0)}\nدفعات تحتاج تعديل=${Number(d?.batchesNeedingFix || 0)}\n\nهل تريد تنفيذ الإصلاح الآن؟`);
            if (!ok2) return;
            const run = await supabase.rpc('repair_item_purchase_costs', { p_item_id: item.id, p_warehouse_id: warehouseId || null, p_dry_run: false } as any);
            if ((run as any)?.error) throw (run as any).error;
            const r: any = (run as any)?.data || {};
            showNotification(
                `تم الإصلاح: سندات=${Number(r?.receiptItemsUpdated || 0)}، دفعات=${Number(r?.batchesUpdated || 0)}، حركات شراء=${Number(r?.purchaseInMovementsUpdated || 0)}.`,
                'success'
            );
            await refreshBatches();
        } catch (e) {
            const msg = localizeSupabaseError(e) || getErrorMessage(e, 'فشل إصلاح تكلفة الصنف.');
            showNotification(msg, 'error');
        } finally {
            setRepairCostBusy(false);
        }
    };

    const revalueSelectedBatchCost = async () => {
        if (!canRepairCost) return;
        if (revalueBatchBusy) return;
        const supabase = getSupabaseClient();
        if (!supabase) {
            showNotification('قاعدة البيانات غير متاحة.', 'error');
            return;
        }
        const targetBatchId = String(selectedBatchId || (batches[0]?.batchId || '')).trim();
        if (!targetBatchId) {
            showNotification('لا توجد دفعة صالحة لتعديل تكلفتها.', 'error');
            return;
        }
        const costStr = window.prompt(`أدخل التكلفة الصحيحة لكل وحدة أساسية (${baseCode || 'BASE'}).\nسيتم تطبيقها على الدفعة: ${targetBatchId.slice(0, 8)}\nمثال: 0.52`, '');
        if (!costStr) return;
        const newCost = Number(String(costStr).replace(',', '.'));
        if (!Number.isFinite(newCost) || newCost <= 0) {
            showNotification('قيمة التكلفة غير صحيحة.', 'error');
            return;
        }
        const reason = (window.prompt('أدخل سبب تعديل التكلفة (إلزامي):', '') || '').trim();
        if (!reason) return;
        const ok = window.confirm(`سيتم تعديل تكلفة الدفعة (${targetBatchId.slice(0, 8)}) إلى ${newCost} ${baseCode || ''}.\nوسيتم إنشاء قيد تسوية (Revaluation) تلقائيًا إن أمكن.\nهل تريد المتابعة؟`);
        if (!ok) return;
        setRevalueBatchBusy(true);
        try {
            const res = await supabase.rpc('revalue_batch_unit_cost', {
                p_batch_id: targetBatchId,
                p_new_unit_cost: newCost,
                p_reason: reason,
                p_post_journal: true,
            } as any);
            if ((res as any)?.error) throw (res as any).error;
            const d: any = (res as any)?.data || {};
            showNotification(`تم تعديل تكلفة الدفعة: ${Number(d?.oldUnitCost || 0)} → ${Number(d?.newUnitCost || 0)} ${baseCode || ''}`, 'success');
            await refreshBatches();
        } catch (e) {
            const msg = localizeSupabaseError(e) || getErrorMessage(e, 'فشل تعديل تكلفة الدفعة.');
            showNotification(msg, 'error');
        } finally {
            setRevalueBatchBusy(false);
        }
    };

    const onStockChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        setLocalStock(e.target.value);
    };

    const onMinStockChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        setLocalMinStock(e.target.value);
    };

    const onStockBlur = () => {
        if (readOnlyMode) {
            setLocalStock(String(currentStock));
            return;
        }
        const val = parseFloat(localStock);
        const minVal = localMinStock ? parseFloat(localMinStock) : undefined;
        if (!Number.isNaN(val) && val !== currentStock) {
            handleUpdateStock(item.id, val, unit, selectedBatchId || undefined, Number.isNaN(minVal!) ? undefined : minVal);
        } else {
            setLocalStock(String(currentStock));
        }
    };

    const onMinStockBlur = () => {
        if (readOnlyMode) {
            setLocalMinStock(String(stock?.minimumStockLevel ?? ''));
            return;
        }
        const minVal = localMinStock ? parseFloat(localMinStock) : undefined;
        const currentMin = stock?.minimumStockLevel;
        if (!Number.isNaN(minVal!) && minVal !== currentMin) {
            handleUpdateStock(item.id, currentStock, unit, selectedBatchId || undefined, minVal);
        } else if (localMinStock === '' && currentMin !== undefined) {
            // they cleared it, we could pass null but we'll map undefined
            handleUpdateStock(item.id, currentStock, unit, selectedBatchId || undefined, 0);
        } else {
            setLocalMinStock(String(currentMin ?? ''));
        }
    };

    const onStockKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
        if (e.key === 'Enter') {
            e.currentTarget.blur();
        }
    };

    return (
        <tr className={isLowStock ? 'bg-red-50 dark:bg-red-900/10' : ''}>
            <td className="px-6 py-4 whitespace-nowrap border-r dark:border-gray-700">
                <div className="flex items-center">
                    <img src={item.imageUrl || undefined} alt={itemName} className="w-10 h-10 rounded-md object-cover" />
                    <div className="mr-4 rtl:mr-0 rtl:ml-4">
                        <div className="text-sm font-medium text-gray-900 dark:text-white">
                            {itemName}
                        </div>
                    </div>
                </div>
            </td>
            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400 border-r dark:border-gray-700">
                {getCategoryLabel(item.category, 'ar')}
            </td>
            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400 border-r dark:border-gray-700">
                {getUnitLabel(unit as any, 'ar')}
            </td>
            <td className="px-6 py-4 whitespace-nowrap border-r dark:border-gray-700" dir="ltr">
                <span className={`text-sm font-semibold ${isLowStock ? 'text-red-600 dark:text-red-400' : 'text-gray-900 dark:text-white'}`}>
                    {Number(currentStock || 0).toLocaleString('en-US', { maximumFractionDigits: 2 })}
                </span>
            </td>
            <td className="px-6 py-4 whitespace-nowrap text-sm text-purple-700 dark:text-purple-300 border-r dark:border-gray-700" dir="ltr">
                {Number(qcHold || 0).toLocaleString('en-US', { maximumFractionDigits: 2 })}
            </td>
            <td className="px-6 py-4 whitespace-nowrap text-sm text-orange-600 dark:text-orange-400 border-r dark:border-gray-700" dir="ltr">
                {Number(reserved || 0).toLocaleString('en-US', { maximumFractionDigits: 2 })}
            </td>
            <td className="px-6 py-4 whitespace-nowrap border-r dark:border-gray-700" dir="ltr">
                <span className={`text-sm font-semibold ${isLowStock ? 'text-red-600 dark:text-red-400' : 'text-green-600 dark:text-green-400'}`}>
                    {Number(available || 0).toLocaleString('en-US', { maximumFractionDigits: 2 })}
                </span>
            </td>
            <td className="px-6 py-4 whitespace-nowrap">
                <div className="flex items-center gap-2">
                    <button
                        onClick={() => handleUpdateStock(item.id, currentStock - 1, unit, selectedBatchId || undefined, localMinStock ? parseFloat(localMinStock) : undefined)}
                        disabled={readOnlyMode}
                        className="p-1 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded"
                    >
                        <MinusIcon />
                    </button>
                    <input
                        type="number"
                        value={localStock}
                        onChange={onStockChange}
                        onBlur={onStockBlur}
                        onKeyDown={onStockKeyDown}
                        disabled={readOnlyMode}
                        className="w-20 px-2 py-1 text-center border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                        min="0"
                        step={unit === 'kg' || unit === 'gram' ? '0.5' : '1'}
                    />
                    <button
                        onClick={() => handleUpdateStock(item.id, currentStock + 1, unit, selectedBatchId || undefined, localMinStock ? parseFloat(localMinStock) : undefined)}
                        disabled={readOnlyMode}
                        className="p-1 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded"
                    >
                        <PlusIcon />
                    </button>
                </div>
                <div className="mt-2 flex items-center gap-2">
                    <label className="text-sm font-medium text-gray-700 dark:text-gray-300 whitespace-nowrap">
                        الحد الأدنى للتنبيه:
                    </label>
                    <input
                        type="number"
                        value={localMinStock}
                        onChange={onMinStockChange}
                        onBlur={onMinStockBlur}
                        onKeyDown={onStockKeyDown}
                        disabled={readOnlyMode}
                        placeholder={String(stock?.lowStockThreshold ?? 5)}
                        className="w-20 px-2 py-1 text-center border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                        min="0"
                        step={unit === 'kg' || unit === 'gram' ? '0.5' : '1'}
                    />
                </div>
                {!readOnlyMode && (
                    <div className="mt-2">
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                            اختيار الدُفعة
                        </label>
                        <select
                            value={selectedBatchId}
                            onChange={(e) => setSelectedBatchId(e.target.value)}
                            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                        >
                            <option value="">الدفعة الأخيرة</option>
                            {batches.map((b) => (
                                <option key={b.batchId} value={b.batchId}>
                                    {String(b.batchId).slice(0, 8)} • {qcStatusLabel(String((b as any).qcStatus || ''))} • متبقٍ {Number(b.remainingQuantity || 0).toLocaleString('en-US')}
                                </option>
                            ))}
                        </select>
                    </div>
                )}
                {!readOnlyMode && (
                    <button
                        type="button"
                        onClick={() => setShowBatches(prev => !prev)}
                        className="mt-2 w-full px-3 py-2 bg-gray-200 text-gray-800 rounded-md hover:bg-gray-300 transition text-sm font-semibold dark:bg-gray-700 dark:text-gray-200 dark:hover:bg-gray-600"
                    >
                        {showBatches ? 'إخفاء الدُفعات / QC' : 'دفعات المخزون / QC'}
                    </button>
                )}
                {!readOnlyMode && showBatches && (
                    <div className="mt-2 p-3 rounded-md bg-gray-50 dark:bg-gray-900/40 border border-gray-200 dark:border-gray-700">
                        {(batches || []).length > 0 ? (
                            <ul className="space-y-2 text-xs">
                                {batches.slice(0, 5).map((b) => (
                                    <li key={b.batchId} className="text-gray-700 dark:text-gray-200">
                                        <div className="flex items-start justify-between gap-2">
                                            <div className="min-w-0">
                                                <div className="font-semibold">
                                                    {String(b.batchId).slice(0, 8)} • كلفة أساسية {Number((b as any).unitCost || 0).toLocaleString('en-US')} {baseCode || '—'}
                                                    {((b as any).unitCostOriginal && (b as any).unitCostCurrency) ? (
                                                        <>
                                                            {' '}• كلفة المورد {Number((b as any).unitCostOriginal).toLocaleString('en-US')} {(b as any).unitCostCurrency}
                                                            {Number((b as any).fxAtReceipt || 0) > 0 ? ` • FX ${Number((b as any).fxAtReceipt).toFixed(6)}` : ''}
                                                            {Number((b as any).fxAtReceipt || 0) > 0 ? ` • محسوبة ${Number((Number((b as any).unitCostOriginal || 0) * Number((b as any).fxAtReceipt || 0)) || 0).toLocaleString('en-US')} ${baseCode || '—'}` : ''}
                                                        </>
                                                    ) : null}
                                                </div>
                                                {Number((b as any).unitCost || 0) > 0 && Number((b as any).unitCost || 0) < 1 ? (
                                                    <div className="text-amber-700 dark:text-amber-300">
                                                        تنبيه: التكلفة الأساسية أقل من 1 {baseCode || ''}. راجع كلفة المورد وسعر الصرف ووحدة الشراء.
                                                    </div>
                                                ) : null}
                                                <div className="text-gray-500 dark:text-gray-400">
                                                    وارد {Number(b.receivedQuantity || 0).toLocaleString('en-US')} • مستهلك {Number(b.consumedQuantity || 0).toLocaleString('en-US')} • متبقٍ {Number(b.remainingQuantity || 0).toLocaleString('en-US')}
                                                </div>
                                                <div className="text-gray-500 dark:text-gray-400">
                                                    مرتجع مشتريات {Number((b as any).returnedQuantity || 0).toLocaleString('en-US')} • مباع {Number((b as any).soldQuantity || 0).toLocaleString('en-US')} • هالك/تعديل {Number(((b as any).wastageQuantity || 0) + ((b as any).adjustOutQuantity || 0)).toLocaleString('en-US')}
                                                </div>
                                                <div className="text-gray-500 dark:text-gray-400 mt-1">
                                                    QC: {qcStatusLabel(String((b as any).qcStatus || ''))}
                                                    {(b as any).lastQcResult ? ` • آخر نتيجة: ${(b as any).lastQcResult === 'pass' ? 'نجح' : 'فشل'}` : ''}
                                                </div>
                                                {/* Date display */}
                                                <div className="text-gray-500 dark:text-gray-400 mt-1">
                                                    إنتاج: {(b as any).productionDate ? new Date((b as any).productionDate).toLocaleDateString('ar-SA-u-nu-latn') : '—'}
                                                    {' • '}
                                                    <span className={(b as any).expiryDate && new Date((b as any).expiryDate) < new Date() ? 'text-red-600 font-bold' : ''}>
                                                        انتهاء: {(b as any).expiryDate ? new Date((b as any).expiryDate).toLocaleDateString('ar-SA-u-nu-latn') : '—'}
                                                    </span>
                                                </div>
                                                {/* Inline date editing */}
                                                {editingDatesBatchId === String(b.batchId) ? (
                                                    <div className="mt-2 p-2 bg-blue-50 dark:bg-blue-900/20 rounded-md border border-blue-200 dark:border-blue-700 space-y-2">
                                                        <div className="grid grid-cols-2 gap-2">
                                                            <div>
                                                                <label className="block text-xs font-medium text-gray-600 dark:text-gray-400">تاريخ الإنتاج</label>
                                                                <input type="date" value={editProdDate} onChange={(e) => setEditProdDate(e.target.value)} className="w-full px-2 py-1 text-xs border rounded dark:bg-gray-700 dark:border-gray-600" />
                                                            </div>
                                                            <div>
                                                                <label className="block text-xs font-medium text-gray-600 dark:text-gray-400">تاريخ الانتهاء</label>
                                                                <input type="date" value={editExpDate} onChange={(e) => setEditExpDate(e.target.value)} className="w-full px-2 py-1 text-xs border rounded dark:bg-gray-700 dark:border-gray-600" />
                                                            </div>
                                                        </div>
                                                        <div className="flex gap-2">
                                                            <button
                                                                type="button"
                                                                disabled={dateSaveBusy}
                                                                onClick={async () => {
                                                                    setDateSaveBusy(true);
                                                                    try {
                                                                        const supabase = getSupabaseClient();
                                                                        if (!supabase) throw new Error('Supabase not available');
                                                                        const { error } = await supabase.rpc('update_batch_dates', {
                                                                            p_batch_id: b.batchId,
                                                                            p_production_date: editProdDate || null,
                                                                            p_expiry_date: editExpDate || null,
                                                                        } as any);
                                                                        if (error) throw error;
                                                                        showNotification('تم تحديث تواريخ الدفعة بنجاح', 'success');
                                                                        setEditingDatesBatchId(null);
                                                                        await refreshBatches();
                                                                    } catch (err: any) {
                                                                        showNotification(getErrorMessage(err, 'فشل تحديث التواريخ'), 'error');
                                                                    } finally {
                                                                        setDateSaveBusy(false);
                                                                    }
                                                                }}
                                                                className="px-2 py-1 text-xs rounded bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50"
                                                            >
                                                                {dateSaveBusy ? 'جاري...' : 'حفظ'}
                                                            </button>
                                                            <button type="button" onClick={() => setEditingDatesBatchId(null)} className="px-2 py-1 text-xs rounded bg-gray-200 dark:bg-gray-600 text-gray-700 dark:text-gray-200">
                                                                إلغاء
                                                            </button>
                                                        </div>
                                                    </div>
                                                ) : null}
                                                <div className="flex items-center gap-2 mt-2">
                                                    {(String((b as any).qcStatus || '') === 'pending' || String((b as any).qcStatus || '') === 'quarantined') && hasPermission('qc.inspect') && (
                                                        <>
                                                            <button
                                                                type="button"
                                                                onClick={() => runQcInspect(String(b.batchId), 'pass')}
                                                                disabled={qcBusyBatchId === String(b.batchId)}
                                                                className="px-2 py-1 rounded bg-green-600 text-white hover:bg-green-700 disabled:opacity-50"
                                                            >
                                                                فحص (نجح)
                                                            </button>
                                                            <button
                                                                type="button"
                                                                onClick={() => runQcInspect(String(b.batchId), 'fail')}
                                                                disabled={qcBusyBatchId === String(b.batchId)}
                                                                className="px-2 py-1 rounded bg-red-600 text-white hover:bg-red-700 disabled:opacity-50"
                                                            >
                                                                فحص (فشل)
                                                            </button>
                                                        </>
                                                    )}
                                                    {String((b as any).qcStatus || '') === 'inspected' && (b as any).lastQcResult === 'pass' && hasPermission('qc.release') && (
                                                        <button
                                                            type="button"
                                                            onClick={() => runQcRelease(String(b.batchId))}
                                                            disabled={qcBusyBatchId === String(b.batchId)}
                                                            className="px-2 py-1 rounded bg-purple-700 text-white hover:bg-purple-800 disabled:opacity-50"
                                                        >
                                                            إفراج
                                                        </button>
                                                    )}
                                                    <button
                                                        type="button"
                                                        title="تعديل تواريخ الدفعة"
                                                        onClick={() => {
                                                            setEditingDatesBatchId(String(b.batchId));
                                                            setEditProdDate((b as any).productionDate || '');
                                                            setEditExpDate((b as any).expiryDate || '');
                                                        }}
                                                        className="px-2 py-1 rounded bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 hover:bg-blue-200 dark:hover:bg-blue-900/50"
                                                    >
                                                        📅 تعديل التواريخ
                                                    </button>
                                                    <button
                                                        type="button"
                                                        title="طباعة ملصق الدفعة"
                                                        onClick={() => {
                                                            const itemName = (item as any)?.name?.ar || (item as any)?.name?.en || item?.name || '';
                                                            const html = renderToString(
                                                                <BatchLabel
                                                                    itemName={typeof itemName === 'object' ? (itemName as any).ar || (itemName as any).en || '' : String(itemName)}
                                                                    batchCode={String(b.batchId || '').slice(0, 8)}
                                                                    productionDate={(b as any).productionDate || ''}
                                                                    expiryDate={(b as any).expiryDate || ''}
                                                                    quantity={Number(b.remainingQuantity || 0)}
                                                                    unitLabel={String(item?.unitType || '')}
                                                                    barcode={(item as any)?.barcode || ''}
                                                                />
                                                            );
                                                            printContent(html, 'ملصق الدفعة');
                                                        }}
                                                        className="px-2 py-1 rounded bg-gray-200 dark:bg-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-500"
                                                    >
                                                        🏷️ طباعة ملصق
                                                    </button>
                                                </div>
                                            </div>
                                            <div className="shrink-0 text-gray-500 dark:text-gray-400" dir="ltr">
                                                {new Date(b.occurredAt).toLocaleString('ar-EG-u-nu-latn')}
                                            </div>
                                        </div>
                                    </li>
                                ))}
                            </ul>
                        ) : (
                            <div className="text-xs text-gray-500 dark:text-gray-400">لا توجد دفعات لهذا المنتج.</div>
                        )}
                    </div>
                )}
                {!readOnlyMode && canRepairCost ? (
                    <button
                        type="button"
                        onClick={() => { void repairItemCost(); }}
                        disabled={repairCostBusy}
                        className="mt-2 w-full px-3 py-2 bg-purple-700 text-white rounded-md hover:bg-purple-800 transition text-sm font-semibold disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                        {repairCostBusy ? 'جاري إصلاح التكلفة...' : 'إصلاح تكلفة الصنف'}
                    </button>
                ) : null}
                {!readOnlyMode && canRepairCost ? (
                    <button
                        type="button"
                        onClick={() => { void revalueSelectedBatchCost(); }}
                        disabled={revalueBatchBusy}
                        className="mt-2 w-full px-3 py-2 bg-orange-600 text-white rounded-md hover:bg-orange-700 transition text-sm font-semibold disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                        {revalueBatchBusy ? 'جاري تعديل تكلفة الدفعة...' : 'تعديل تكلفة الدفعة'}
                    </button>
                ) : null}
                {!readOnlyMode && (
                    <button
                        type="button"
                        onClick={() => {
                            setWastageItem(item);
                            setIsWastageModalOpen(true);
                        }}
                        className="mt-2 w-full px-3 py-2 bg-red-100 text-red-800 rounded-md hover:bg-red-200 transition text-sm font-semibold dark:bg-red-900/30 dark:text-red-200 dark:hover:bg-red-900/50"
                    >
                        تسجيل تالف
                    </button>
                )}
                <button
                    type="button"
                    onClick={() => toggleHistory(item.id)}
                    className="mt-2 w-full px-3 py-2 bg-gray-200 text-gray-800 rounded-md hover:bg-gray-300 transition text-sm font-semibold dark:bg-gray-700 dark:text-gray-200 dark:hover:bg-gray-600"
                >
                    {expandedHistoryItemId === item.id
                        ? 'إخفاء السجل'
                        : 'سجل التعديلات'}
                </button>
                {expandedHistoryItemId === item.id && (
                    <div className="mt-2 p-3 rounded-md bg-gray-50 dark:bg-gray-900/40 border border-gray-200 dark:border-gray-700">
                        {historyLoadingItemId === item.id ? (
                            <div className="text-xs text-gray-500 dark:text-gray-400">جاري تحميل السجل...</div>
                        ) : (historyByItemId[item.id]?.length || 0) > 0 ? (
                            <ul className="space-y-2 text-xs">
                                {historyByItemId[item.id]!.slice(0, 10).map((h: any) => (
                                    <li key={h.id} className="text-gray-700 dark:text-gray-200">
                                        <div className="flex items-start justify-between gap-2">
                                            <div className="min-w-0">
                                                <div className="font-semibold">
                                                    {h.quantity} {String(h.unit)}
                                                </div>
                                                <div className="text-gray-500 dark:text-gray-400">
                                                    {h.reason}{h.changedBy ? ` • ${h.changedBy}` : ''}
                                                </div>
                                            </div>
                                            <div className="shrink-0 text-gray-500 dark:text-gray-400" dir="ltr">
                                                {new Date(h.date).toLocaleString('ar-EG-u-nu-latn')}
                                            </div>
                                        </div>
                                    </li>
                                ))}
                            </ul>
                        ) : (
                            <div className="text-xs text-gray-500 dark:text-gray-400">لا يوجد سجل لهذا المنتج.</div>
                        )}
                    </div>
                )}
            </td>
        </tr>
    );
};

const ManageStockScreen: React.FC = () => {
    const { menuItems } = useMenu();
    const { stockItems, fetchStock, updateStock, getStockByItemId } = useStock();
    // const { language } = useSettings();
    const { categories: categoryDefs, getCategoryLabel, getGroupLabel, getUnitLabel } = useItemMeta();
    const { showNotification } = useToast();
    const { userId, hasPermission } = useAuth();
    const sessionScope = useSessionScope();
    const { warehouses } = useWarehouses();
    const warehouseId = sessionScope.scope?.warehouseId || '';
    const [pendingWarehouseId, setPendingWarehouseId] = useState('');
    const [viewWarehouseId, setViewWarehouseId] = useState('');
    const [baseCode, setBaseCode] = useState('—');
    const [searchTerm, setSearchTerm] = useState('');
    const [selectedCategory, setSelectedCategory] = useState('all');
    const [reason, setReason] = useState('');
    const [expandedHistoryItemId, setExpandedHistoryItemId] = useState<string | null>(null);
    const [historyLoadingItemId, setHistoryLoadingItemId] = useState<string | null>(null);
    const [historyByItemId, setHistoryByItemId] = useState<Record<string, StockHistory[]>>({});
    const [warehouseSignals, setWarehouseSignals] = useState({ hasMovements: false, hasBatches: false, checking: false });
    const [resyncingWarehouseStock, setResyncingWarehouseStock] = useState(false);
    const [externalStockByItemId, setExternalStockByItemId] = useState<Record<string, StockManagement>>({});
    const [externalStockLoading, setExternalStockLoading] = useState(false);

    const [isWastageModalOpen, setIsWastageModalOpen] = useState(false);
    const [wastageItem, setWastageItem] = useState<MenuItem | null>(null);

    useEffect(() => {
        void getBaseCurrencyCode().then((c) => {
            if (!c) return;
            setBaseCode(c);
        });
    }, []);

    useEffect(() => {
        setPendingWarehouseId(warehouseId);
    }, [warehouseId]);

    const canSwitchWarehouse = hasPermission('stock.manage') || hasPermission('inventory.view');
    const activeWarehouses = useMemo(() => {
        return (warehouses || []).filter((w: any) => Boolean((w as any)?.isActive ?? (w as any)?.is_active ?? true));
    }, [warehouses]);

    const currentWarehouseName = useMemo(() => {
        if (!warehouseId) return '—';
        return String((activeWarehouses.find((w: any) => String(w.id) === String(warehouseId)) as any)?.name || '—');
    }, [activeWarehouses, warehouseId]);
    const effectiveViewWarehouseId = useMemo(() => (viewWarehouseId ? viewWarehouseId : warehouseId), [viewWarehouseId, warehouseId]);
    const isReadOnlyView = useMemo(() => {
        if (!effectiveViewWarehouseId) return true;
        if (effectiveViewWarehouseId === 'all') return true;
        return String(effectiveViewWarehouseId) !== String(warehouseId);
    }, [effectiveViewWarehouseId, warehouseId]);
    const effectiveViewWarehouseName = useMemo(() => {
        if (!effectiveViewWarehouseId) return '—';
        if (effectiveViewWarehouseId === 'all') return 'كل المستودعات';
        return String((activeWarehouses.find((w: any) => String(w.id) === String(effectiveViewWarehouseId)) as any)?.name || '—');
    }, [activeWarehouses, effectiveViewWarehouseId]);

    useEffect(() => {
        if (viewWarehouseId) return;
        if (!warehouseId) return;
        setViewWarehouseId('');
    }, [viewWarehouseId, warehouseId]);

    useEffect(() => {
        let cancelled = false;
        const run = async () => {
            if (!isReadOnlyView) {
                if (!cancelled) {
                    setExternalStockByItemId({});
                    setExternalStockLoading(false);
                }
                return;
            }
            const supabase = getSupabaseClient();
            if (!supabase) return;
            if (!cancelled) setExternalStockLoading(true);
            try {
                let q = supabase
                    .from('stock_management')
                    .select('item_id,warehouse_id,available_quantity,qc_hold_quantity,reserved_quantity,unit,low_stock_threshold,minimum_stock_level,last_updated,avg_cost');
                if (effectiveViewWarehouseId && effectiveViewWarehouseId !== 'all') {
                    q = q.eq('warehouse_id', effectiveViewWarehouseId);
                }
                const { data, error } = await q.limit(50000);
                if (error) throw error;
                const rows = Array.isArray(data) ? data : [];
                const map: Record<string, StockManagement> = {};
                for (const r of rows as any[]) {
                    const itemId = String(r?.item_id || '').trim();
                    if (!itemId) continue;
                    const qty = Number(r?.available_quantity || 0) || 0;
                    const reserved = Number(r?.reserved_quantity || 0) || 0;
                    const qcHold = Number(r?.qc_hold_quantity || 0) || 0;
                    const avgCost = Number(r?.avg_cost || 0) || 0;
                    const unit = String(r?.unit || 'piece') as UnitType;
                    const minLevel = Number(r?.minimum_stock_level ?? 0) || 0;
                    const lowLevel = Number(r?.low_stock_threshold ?? 0) || 0;
                    const updated = String(r?.last_updated || new Date().toISOString());
                    if (!map[itemId]) {
                        map[itemId] = {
                            id: itemId,
                            itemId,
                            warehouseId: String(effectiveViewWarehouseId || 'all'),
                            availableQuantity: qty,
                            qcHoldQuantity: qcHold,
                            unit,
                            reservedQuantity: reserved,
                            lastUpdated: updated,
                            lowStockThreshold: lowLevel || undefined,
                            minimumStockLevel: minLevel || undefined,
                            avgCost: avgCost || undefined,
                        };
                    } else {
                        map[itemId] = {
                            ...map[itemId],
                            availableQuantity: Number(map[itemId].availableQuantity || 0) + qty,
                            qcHoldQuantity: Number(map[itemId].qcHoldQuantity || 0) + qcHold,
                            reservedQuantity: Number(map[itemId].reservedQuantity || 0) + reserved,
                            avgCost: avgCost > 0 ? avgCost : map[itemId].avgCost,
                            minimumStockLevel: minLevel > 0 ? Math.min(Number(map[itemId].minimumStockLevel || minLevel), minLevel) : map[itemId].minimumStockLevel,
                            lowStockThreshold: lowLevel > 0 ? Math.min(Number(map[itemId].lowStockThreshold || lowLevel), lowLevel) : map[itemId].lowStockThreshold,
                            lastUpdated: updated,
                        };
                    }
                }
                if (!cancelled) setExternalStockByItemId(map);
            } catch {
                if (!cancelled) setExternalStockByItemId({});
            } finally {
                if (!cancelled) setExternalStockLoading(false);
            }
        };
        void run();
        return () => { cancelled = true; };
    }, [effectiveViewWarehouseId, isReadOnlyView]);

    useEffect(() => {
        let cancelled = false;
        const run = async () => {
            if (!warehouseId) {
                if (!cancelled) setWarehouseSignals({ hasMovements: false, hasBatches: false, checking: false });
                return;
            }
            if (!cancelled) setWarehouseSignals((prev) => ({ ...prev, checking: true }));
            try {
                const supabase = getSupabaseClient();
                if (!supabase) throw new Error('قاعدة البيانات غير متاحة');
                const [{ data: mvRows }, { data: bRows }] = await Promise.all([
                    supabase.from('inventory_movements').select('id').eq('warehouse_id', warehouseId).limit(1),
                    supabase.from('batches').select('id').eq('warehouse_id', warehouseId).limit(1),
                ]);
                if (!cancelled) {
                    setWarehouseSignals({
                        hasMovements: (mvRows?.length || 0) > 0,
                        hasBatches: (bRows?.length || 0) > 0,
                        checking: false,
                    });
                }
            } catch {
                if (!cancelled) setWarehouseSignals({ hasMovements: false, hasBatches: false, checking: false });
            }
        };
        void run();
        return () => { cancelled = true; };
    }, [warehouseId]);

    const resyncWarehouseStock = async () => {
        if (!warehouseId || resyncingWarehouseStock) return;
        setResyncingWarehouseStock(true);
        try {
            const supabase = getSupabaseClient();
            if (!supabase) throw new Error('قاعدة البيانات غير متاحة');

            const [{ data: mvRows, error: mvErr }, { data: bRows, error: bErr }] = await Promise.all([
                supabase.from('inventory_movements').select('item_id').eq('warehouse_id', warehouseId).limit(5000),
                supabase.from('batches').select('item_id').eq('warehouse_id', warehouseId).limit(5000),
            ]);
            if (mvErr) throw mvErr;
            if (bErr) throw bErr;

            const itemIds = new Set<string>();
            for (const r of (Array.isArray(mvRows) ? mvRows : [])) {
                const id = String((r as any)?.item_id || '').trim();
                if (id) itemIds.add(id);
            }
            for (const r of (Array.isArray(bRows) ? bRows : [])) {
                const id = String((r as any)?.item_id || '').trim();
                if (id) itemIds.add(id);
            }

            if (itemIds.size === 0) {
                showNotification('لا توجد حركات/دفعات لإعادة المزامنة في هذا المستودع.', 'error');
                return;
            }

            for (const itemId of itemIds) {
                const { error } = await supabase.rpc('recompute_stock_for_item', { p_item_id: itemId, p_warehouse_id: warehouseId } as any);
                if (error) throw error;
            }

            await fetchStock();
            showNotification('تمت مزامنة رصيد المستودع بنجاح.', 'success');
        } catch (e: any) {
            showNotification(String(e?.message || 'تعذر مزامنة رصيد المستودع'), 'error');
        } finally {
            setResyncingWarehouseStock(false);
        }
    };

    const saveActiveWarehouse = async (targetWarehouseId?: string, silent = false) => {
        try {
            const supabase = getSupabaseClient();
            if (!supabase || !userId) return;
            const wid = String(targetWarehouseId ?? pendingWarehouseId ?? '').trim();
            if (!wid) {
                if (!silent) showNotification('اختر مستودعًا أولاً.', 'error');
                return;
            }
            const exists = activeWarehouses.some((w: any) => String(w.id) === wid);
            if (!exists) {
                if (!silent) showNotification('المستودع المحدد غير نشط.', 'error');
                return;
            }
            const { error } = await supabase
                .from('admin_users')
                .update({ warehouse_id: wid })
                .eq('auth_user_id', userId);
            if (error) throw error;
            await sessionScope.refreshScope();
            setPendingWarehouseId(wid);
            if (!silent) showNotification('تم تغيير المستودع النشط للجلسة.', 'success');
        } catch (e: any) {
            if (!silent) showNotification(String(e?.message || 'تعذر تحديث المستودع النشط'), 'error');
        }
    };

    // Get unique categories
    const categories = useMemo(() => {
        const activeKeys = categoryDefs.filter(c => c.isActive).map(c => c.key);
        const usedKeys = [...new Set(menuItems.map((item: MenuItem) => item.category))].filter(Boolean);
        const merged = Array.from(new Set([...activeKeys, ...usedKeys])).sort((a, b) => a.localeCompare(b));
        return ['all', ...merged];
    }, [categoryDefs, menuItems]);

    // Filter items
    const [selectedGroup, setSelectedGroup] = useState('all');
    const filteredItems = useMemo(() => {
        return menuItems.filter((item: MenuItem) => {
            const itemName = item.name?.['ar'] || item.name?.en || '';
            const matchesSearch = itemName.toLowerCase().includes(searchTerm.toLowerCase());
            const matchesCategory = selectedCategory === 'all' || item.category === selectedCategory;
            const matchesGroup = selectedGroup === 'all' || String((item as any).group || '') === selectedGroup;
            return matchesSearch && matchesCategory && matchesGroup && item.status === 'active';
        });
    }, [menuItems, searchTerm, selectedCategory, selectedGroup]);

    const handleUpdateStock = async (itemId: string, newQuantity: number, unit: string, batchId?: string, minStock?: number) => {
        if (isReadOnlyView) {
            showNotification('وضع العرض الحالي للقراءة فقط. غيّر العرض إلى المستودع النشط للجلسة لتفعيل التعديل.', 'error');
            return;
        }
        if (newQuantity < 0) return;
        if (!reason.trim()) {
            showNotification('سبب تعديل المخزون مطلوب.', 'error');
            return;
        }
        try {
            await updateStock(itemId, newQuantity, unit, reason, batchId, minStock);
        } catch (error) {
            const raw = error instanceof Error ? error.message : '';
            const message = raw && /[\u0600-\u06FF]/.test(raw) ? raw : 'فشل تحديث المخزون';
            showNotification(message, 'error');
        }
    };

    const toggleHistory = async (itemId: string) => {
        if (expandedHistoryItemId === itemId) {
            setExpandedHistoryItemId(null);
            return;
        }

        setExpandedHistoryItemId(itemId);
        if (historyByItemId[itemId]) return;

        setHistoryLoadingItemId(itemId);
        try {
            const supabase = getSupabaseClient();
            if (!supabase) {
                throw new Error('Supabase غير مهيأ.');
            }
            const { data: rows, error } = await supabase
                .from('stock_history')
                .select('id,item_id,date,quantity,unit,reason,data,created_at')
                .eq('item_id', itemId)
                .order('date', { ascending: false })
                .limit(60);
            if (error) throw error;
            const history = (rows || []).map((r: any) => {
                const d = (r?.data && typeof r.data === 'object') ? r.data : {};
                return {
                    id: r.id,
                    itemId: r.item_id,
                    quantity: Number(r.quantity ?? d.quantity ?? 0),
                    unit: String(r.unit ?? d.unit ?? 'piece'),
                    date: String(r.date ?? d.date ?? new Date().toISOString()),
                    reason: String(r.reason ?? d.reason ?? ''),
                    changedBy: d.changedBy ? String(d.changedBy) : undefined
                } as StockHistory;
            }).filter(Boolean);
            setHistoryByItemId(prev => ({ ...prev, [itemId]: history }));
        } catch (error) {
            const raw = error instanceof Error ? error.message : '';
            const message = raw && /[\u0600-\u06FF]/.test(raw) ? raw : 'فشل تحميل سجل المخزون.';
            showNotification(message, 'error');
        } finally {
            setHistoryLoadingItemId(null);
        }
    };
    const getDisplayStockByItemId = (itemId: string) => {
        if (!isReadOnlyView) return getStockByItemId(itemId);
        return externalStockByItemId[itemId];
    };

    return (
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
            <div className="mb-8">
                <div className="flex items-center justify-between gap-3 flex-wrap">
                    <div>
                        <h1 className="text-3xl font-bold text-gray-900 dark:text-white mb-2">
                            إدارة المخزون
                        </h1>
                        <p className="text-gray-600 dark:text-gray-400">
                            تحديث وإدارة كميات المخزون المتوفرة
                        </p>
                    </div>
                    {canSwitchWarehouse && (
                        <div className="flex items-center gap-2">
                            <select
                                value={pendingWarehouseId || ''}
                                onChange={(e) => {
                                    const wid = String(e.target.value || '');
                                    setPendingWarehouseId(wid);
                                    if (wid && wid !== warehouseId) {
                                        void saveActiveWarehouse(wid, true);
                                    }
                                }}
                                className="px-3 py-2 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                            >
                                <option value="" disabled>اختر المستودع</option>
                                {activeWarehouses.map((w: any) => (
                                    <option key={String(w.id)} value={String(w.id)}>
                                        {String((w as any).name || '')}
                                    </option>
                                ))}
                            </select>
                            <button
                                onClick={() => { void saveActiveWarehouse(); }}
                                className="px-3 py-2 rounded bg-blue-600 hover:bg-blue-700 text-white text-sm disabled:opacity-60"
                                disabled={!pendingWarehouseId || pendingWarehouseId === warehouseId}
                            >
                                تعيين للجلسة
                            </button>
                        </div>
                    )}
                </div>
                <div className="mt-2 text-sm text-gray-500 dark:text-gray-400">
                    المستودع الحالي: {currentWarehouseName}
                </div>
                {isReadOnlyView && (
                    <div className="mt-2 text-sm bg-amber-50 text-amber-800 dark:bg-amber-900/20 dark:text-amber-200 border border-amber-200 dark:border-amber-800 rounded px-3 py-2">
                        وضع عرض فقط — يتم عرض بيانات المخزون لـ: <span className="font-semibold">{effectiveViewWarehouseName}</span>، والتعديل متاح فقط عند اختيار "المستودع النشط للجلسة".
                    </div>
                )}
            </div>

            {/* Filters */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-md p-6 mb-6">
                <div className="grid grid-cols-1 md:grid-cols-5 gap-4">
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
                    <div>
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                            نطاق العرض
                        </label>
                        <select
                            value={viewWarehouseId}
                            onChange={(e) => setViewWarehouseId(String(e.target.value || ''))}
                            className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-gold-500"
                        >
                            <option value="">المستودع النشط للجلسة</option>
                            <option value="all">كل المستودعات (قراءة فقط)</option>
                            {activeWarehouses.map((w: any) => (
                                <option key={String(w.id)} value={String(w.id)}>
                                    {String((w as any).name || '')}{String(w.id) === String(warehouseId) ? '' : ' (قراءة فقط)'}
                                </option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                            سبب التعديل
                        </label>
                        <input
                            type="text"
                            value={reason}
                            onChange={(e) => setReason(e.target.value)}
                            disabled={isReadOnlyView}
                            placeholder="مثال: جرد يومي / تلف / توريد جديد"
                            className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-gold-500"
                        />
                    </div>
                </div>
            </div>

            {/* Stock Table */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden">
                {!isReadOnlyView && warehouseId && stockItems.length === 0 && (
                    <div className="px-6 py-3 text-sm bg-amber-50 text-amber-800 dark:bg-amber-900/20 dark:text-amber-200 border-b border-amber-200 dark:border-amber-800 flex items-center justify-between gap-3 flex-wrap">
                        <span>
                            {(warehouseSignals.hasMovements || warehouseSignals.hasBatches)
                                ? 'توجد حركات/دفعات في هذا المستودع لكن لا توجد سجلات في stock_management بعد. جرّب مزامنة الرصيد.'
                                : 'لا توجد سجلات مخزون مرتبطة بهذا المستودع حالياً. تأكد أنك اخترت المستودع الصحيح وأن الأصناف نُقلت/استُلمت عليه.'}
                        </span>
                        {(hasPermission('stock.manage') && (warehouseSignals.hasMovements || warehouseSignals.hasBatches)) && (
                            <button
                                type="button"
                                onClick={() => { void resyncWarehouseStock(); }}
                                disabled={resyncingWarehouseStock || warehouseSignals.checking}
                                className="px-3 py-1.5 rounded bg-amber-600 hover:bg-amber-700 text-white text-xs disabled:opacity-60"
                            >
                                {resyncingWarehouseStock ? 'جاري المزامنة...' : 'مزامنة رصيد المستودع'}
                            </button>
                        )}
                    </div>
                )}
                {isReadOnlyView && externalStockLoading && (
                    <div className="px-6 py-3 text-sm bg-blue-50 text-blue-800 dark:bg-blue-900/20 dark:text-blue-200 border-b border-blue-200 dark:border-blue-800">
                        جاري تحميل بيانات المخزون لنطاق العرض المحدد...
                    </div>
                )}
                <div className="overflow-x-auto">
                    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                        <thead className="bg-gray-50 dark:bg-gray-900">
                            <tr>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    المنتج
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    الفئة
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    الوحدة
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    المخزون الحالي
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    قيد الفحص
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    محجوز
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    متاح
                                </th>
                                <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                    تحديث
                                </th>
                            </tr>
                        </thead>
                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {filteredItems.map((item: MenuItem) => {
                                const stock = getDisplayStockByItemId(item.id);
                                return (
                                    <StockRow
                                        key={item.id}
                                        item={item}
                                        stock={stock}
                                        warehouseId={isReadOnlyView ? (effectiveViewWarehouseId === 'all' ? '' : String(effectiveViewWarehouseId || '')) : warehouseId}
                                        readOnlyMode={isReadOnlyView}
                                        baseCode={baseCode}
                                        getCategoryLabel={getCategoryLabel}
                                        getUnitLabel={getUnitLabel}
                                        handleUpdateStock={handleUpdateStock}
                                        toggleHistory={toggleHistory}
                                        expandedHistoryItemId={expandedHistoryItemId}
                                        historyLoadingItemId={historyLoadingItemId}
                                        historyByItemId={historyByItemId}
                                        setIsWastageModalOpen={setIsWastageModalOpen}
                                        setWastageItem={setWastageItem}
                                    />
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

            {/* Summary */}
            <div className="mt-6 grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4 border-2 border-green-500">
                    <h3 className="text-sm font-medium text-green-800 dark:text-green-400 mb-1">
                        منتجات متوفرة
                    </h3>
                    <p className="text-2xl font-bold text-green-600 dark:text-green-400">
                        {filteredItems.filter(item => {
                            const stock = getDisplayStockByItemId(item.id);
                            const available = Number(stock?.availableQuantity ?? 0) - Number(stock?.reservedQuantity ?? 0);
                            return available > 5;
                        }).length}
                    </p>
                </div>
                <div className="bg-orange-50 dark:bg-orange-900/20 rounded-lg p-4 border-2 border-orange-500">
                    <h3 className="text-sm font-medium text-orange-800 dark:text-orange-400 mb-1">
                        مخزون منخفض
                    </h3>
                    <p className="text-2xl font-bold text-orange-600 dark:text-orange-400">
                        {filteredItems.filter(item => {
                            const stock = getDisplayStockByItemId(item.id);
                            const available = Number(stock?.availableQuantity ?? 0) - Number(stock?.reservedQuantity ?? 0);
                            return available > 0 && available <= 5;
                        }).length}
                    </p>
                </div>
                <div className="bg-red-50 dark:bg-red-900/20 rounded-lg p-4 border-2 border-red-500">
                    <h3 className="text-sm font-medium text-red-800 dark:text-red-400 mb-1">
                        نفذت الكمية
                    </h3>
                    <p className="text-2xl font-bold text-red-600 dark:text-red-400">
                        {filteredItems.filter(item => {
                            const stock = getDisplayStockByItemId(item.id);
                            const available = Number(stock?.availableQuantity ?? 0) - Number(stock?.reservedQuantity ?? 0);
                            return available <= 0;
                        }).length}
                    </p>
                </div>
            </div>

            {wastageItem && (
                <RecordWastageModal
                    isOpen={isWastageModalOpen}
                    onClose={() => {
                        setIsWastageModalOpen(false);
                        setWastageItem(null);
                    }}
                    item={wastageItem}
                />
            )}
        </div>
    );
};

export default ManageStockScreen;
