import React, { useEffect, useState } from 'react';
import { useOrders } from '../../contexts/OrderContext';
import { useToast } from '../../contexts/ToastContext';
import {
    DashboardProvider,
    DashboardHeader,
    KPIBar,
    InventorySection,
    SalesSection,
    PurchasingSection
} from '../../components/dashboard/WorldClassWidgets';
import type { Order, OrderStatus } from '../../types';
import { adminStatusColors } from '../../utils/orderUtils';

// ─── RECENT ORDERS (Simple Table) ──────────────────────────────────────────

const RecentOrdersTable: React.FC = () => {
    const { orders, updateOrderStatus } = useOrders();
    const { showNotification } = useToast();
    const [recentOrders, setRecentOrders] = useState<Order[]>([]);

    useEffect(() => {
        // Take last 5 orders
        setRecentOrders([...orders].sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()).slice(0, 5));
    }, [orders]);

    const handleStatusChange = async (orderId: string, newStatus: OrderStatus) => {
        try {
            await updateOrderStatus(orderId, newStatus);
            showNotification('تم تحديث حالة الطلب بنجاح', 'success');
        } catch (error) {
            showNotification('فشل تحديث حالة الطلب', 'error');
        }
    };

    const statusTranslations: Record<string, string> = {
        pending: 'قيد الانتظار',
        preparing: 'جاري التحضير',
        out_for_delivery: 'خرج للتوصيل',
        delivered: 'تم التوصيل',
        scheduled: 'مجدول',
        cancelled: 'ملغي',
    };

    if (recentOrders.length === 0) {
        return <div className="text-center p-8 text-gray-500 font-bold dark:text-gray-400">لا توجد طلبات حديثة.</div>;
    }

    return (
        <div className="overflow-x-auto bg-white dark:bg-gray-800 rounded-2xl shadow-sm border border-gray-100 dark:border-gray-700">
            <table className="w-full text-sm text-right">
                <thead className="bg-gray-50 dark:bg-gray-700 text-gray-500 dark:text-gray-300 font-medium border-b border-gray-100 dark:border-gray-600">
                    <tr>
                        <th className="px-6 py-4">رقم الطلب</th>
                        <th className="px-6 py-4">العميل</th>
                        <th className="px-6 py-4">التاريخ</th>
                        <th className="px-6 py-4">الإجمالي</th>
                        <th className="px-6 py-4">الحالة</th>
                        <th className="px-6 py-4">إجراء</th>
                    </tr>
                </thead>
                <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-800 dark:text-gray-200">
                    {recentOrders.map(order => (
                        <tr key={order.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition">
                            <td className="px-6 py-4 font-mono">#{order.id.split('-')[0].slice(-4)}</td>
                            <td className="px-6 py-4">{order.customerName || 'عميل محلي'}</td>
                            <td className="px-6 py-4 text-gray-500" dir="ltr">{new Date(order.createdAt).toLocaleDateString('en-GB')}</td>
                            <td className="px-6 py-4 font-bold text-indigo-600 font-mono" dir="ltr">
                                {Number(order.total || 0).toLocaleString()} {String((order as any).currency || '').toUpperCase()}
                            </td>
                            <td className="px-6 py-4">
                                <span className={`px-3 py-1 rounded-full text-xs font-bold ${adminStatusColors[order.status]}`}>
                                    {statusTranslations[order.status]}
                                </span>
                            </td>
                            <td className="px-6 py-4">
                                <select
                                    value={order.status}
                                    onChange={(e) => handleStatusChange(order.id, e.target.value as OrderStatus)}
                                    className="bg-gray-50 dark:bg-gray-700 border border-gray-200 dark:border-gray-600 rounded px-2 py-1 text-xs focus:ring-1 focus:ring-indigo-500"
                                >
                                    {Object.keys(statusTranslations).map(s => (
                                        <option key={s} value={s}>{statusTranslations[s]}</option>
                                    ))}
                                </select>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
};

// ─── MAIN SCREEN ───────────────────────────────────────────────────────────

const AdminDashboardScreen: React.FC = () => {
    return (
        <DashboardProvider>
            <div className="animate-fade-in space-y-8">
                <DashboardHeader title="لوحة التحكم" />

                {/* 1. KPIs */}
                <KPIBar />

                {/* 2. Main Grid */}
                <div className="grid grid-cols-1 xl:grid-cols-4 gap-6">
                    {/* Inventory (Left) - 1 col */}
                    <div className="xl:col-span-1 space-y-6 min-h-[400px]">
                        <InventorySection />
                    </div>

                    {/* Sales (Center) - 2 cols */}
                    <div className="xl:col-span-2 space-y-6 min-h-[400px]">
                        <SalesSection />
                    </div>

                    {/* Purchasing (Right) - 1 col */}
                    <div className="xl:col-span-1 space-y-6 min-h-[400px]">
                        <PurchasingSection />
                    </div>
                </div>

                {/* 3. Recent Orders Table */}
                <div>
                    <h3 className="text-xl font-bold dark:text-white mb-4 px-2">أحدث الطلبات</h3>
                    <RecentOrdersTable />
                </div>
            </div>
        </DashboardProvider>
    );
};

export default AdminDashboardScreen;
