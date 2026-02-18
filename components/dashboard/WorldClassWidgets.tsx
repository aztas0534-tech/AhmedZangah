import React, { createContext, useContext, useState, useEffect, useMemo, useRef } from 'react';
import { getSupabaseClient, getBaseCurrencyCode } from '../../supabase';
import { useAuth } from '../../contexts/AuthContext';
import * as Icons from '../icons';
import { exportToXlsx } from '../../utils/export';

// ─── CONTEXT ───────────────────────────────────────────────────────────────

type DateRange = { start: Date; end: Date; label: string };

type DashboardContextType = {
    dateRange: DateRange;
    setDateRange: (range: DateRange) => void;
    currency: string;
    refreshKey: number;
    triggerRefresh: () => void;
    kpiData: any;
    setKpiData: (data: any) => void;
};

const DashboardContext = createContext<DashboardContextType | undefined>(undefined);

export const useDashboard = () => {
    const context = useContext(DashboardContext);
    if (!context) throw new Error('useDashboard must be used within a DashboardProvider');
    return context;
};

export const DashboardProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
    // Default to "Last 30 Days" for better trend visualization
    const defaultEnd = new Date();
    defaultEnd.setHours(23, 59, 59, 999);
    const defaultStart = new Date();
    defaultStart.setDate(defaultStart.getDate() - 30);
    defaultStart.setHours(0, 0, 0, 0);

    const [dateRange, setDateRange] = useState<DateRange>({
        start: defaultStart,
        end: defaultEnd,
        label: 'آخر 30 يوم'
    });

    const [currency, setCurrency] = useState('ر.ي');
    const [refreshKey, setRefreshKey] = useState(0);
    const [kpiData, setKpiData] = useState<any>(null); // Shared for export

    useEffect(() => {
        getBaseCurrencyCode().then(c => { if (c) setCurrency(c); });
    }, []);

    const triggerRefresh = () => setRefreshKey(p => p + 1);

    return (
        <DashboardContext.Provider value={{ dateRange, setDateRange, currency, refreshKey, triggerRefresh, kpiData, setKpiData }}>
            {children}
        </DashboardContext.Provider>
    );
};

// ─── UTILS ─────────────────────────────────────────────────────────────────

const fmt = (n: number) => n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fmtInt = (n: number) => n.toLocaleString('en-US');

// Skeleton
const Skeleton: React.FC<{ className?: string }> = ({ className = '' }) => (
    <div className={`bg-gray-200 dark:bg-gray-700 animate-pulse rounded ${className}`} />
);

// ─── COMPONENTS ────────────────────────────────────────────────────────────

// 1. GLOBAL DATE PICKER & EXPORT
export const DashboardHeader: React.FC<{ title: string }> = ({ title }) => {
    const { dateRange, setDateRange, triggerRefresh, kpiData, currency } = useDashboard();
    const [isOpen, setIsOpen] = useState(false);
    const [exporting, setExporting] = useState(false);

    const presets = [
        { label: 'اليوم', days: 0 },
        { label: 'أمس', days: 1, offset: 1 },
        { label: 'آخر 7 أيام', days: 7 },
        { label: 'آخر 30 يوم', days: 30 },
        { label: 'هذا الشهر', mode: 'month' },
    ];

    const handleSelect = (p: any) => {
        const end = new Date();
        end.setHours(23, 59, 59, 999);
        const start = new Date();
        start.setHours(0, 0, 0, 0);

        if (p.mode === 'month') {
            start.setDate(1);
        } else if (p.offset) {
            start.setDate(start.getDate() - p.offset);
            end.setDate(end.getDate() - p.offset);
        } else {
            start.setDate(start.getDate() - (p.days || 0));
        }

        setDateRange({ start, end, label: p.label });
        setIsOpen(false);
        triggerRefresh();
    };

    const handleExport = async () => {
        if (!kpiData) return;
        setExporting(true);
        try {
            const headers = ['Metric', 'Value', 'Unit'];
            const rows = [
                ['Sales', kpiData.sales || 0, currency],
                ['Orders', kpiData.orders || 0, 'Orders'],
                ['Margin', kpiData.margin || 0, '%'],
                ['Inventory Value', kpiData.inventoryValue || 0, currency],
                ['POs In Transit', kpiData.transit || 0, 'Orders'],
                ['Export Date', new Date().toLocaleString(), '']
            ];

            await exportToXlsx(headers, rows, `dashboard_report_${new Date().toISOString().split('T')[0]}`);
        } finally {
            setExporting(false);
        }
    };

    return (
        <div className="flex flex-col md:flex-row justify-between items-start md:items-center mb-8 gap-4">
            <div>
                <h1 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center gap-2">
                    <Icons.AdminIcon className="w-8 h-8 text-indigo-600" />
                    {title}
                </h1>
                <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
                    نظرة عامة على أداء مشروعك ومتابعة العمليات اليومية
                </p>
            </div>

            <div className="flex items-center gap-3">
                {/* Export Button */}
                <button
                    onClick={handleExport}
                    disabled={exporting || !kpiData}
                    className="flex items-center gap-2 bg-indigo-50 dark:bg-indigo-900/20 text-indigo-600 dark:text-indigo-400 border border-indigo-100 dark:border-indigo-800 px-4 py-2 rounded-lg shadow-sm hover:bg-indigo-100 dark:hover:bg-indigo-900/30 transition disabled:opacity-50"
                    title="تصدير التقرير"
                >
                    <Icons.DownloadIcon className="w-5 h-5" />
                    <span className="hidden sm:inline text-sm font-medium">تصدير</span>
                </button>

                {/* Date Picker */}
                <div className="relative">
                    <button
                        onClick={() => setIsOpen(!isOpen)}
                        className="flex items-center gap-2 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 px-4 py-2 rounded-lg shadow-sm hover:bg-gray-50 dark:hover:bg-gray-700 transition lg:min-w-[200px] justify-between"
                    >
                        <div className="flex items-center gap-2">
                            <Icons.Calendar className="w-5 h-5 text-gray-500" />
                            <span className="text-sm font-medium dark:text-gray-200">{dateRange.label}</span>
                        </div>
                        <Icons.ArrowRight className={`w-4 h-4 text-gray-400 transform transition ${isOpen ? '-rotate-90' : 'rotate-90'}`} />
                    </button>

                    {isOpen && (
                        <div className="absolute top-full left-0 mt-2 w-56 bg-white dark:bg-gray-800 rounded-xl shadow-xl border border-gray-100 dark:border-gray-700 z-50 overflow-hidden">
                            {presets.map((p) => (
                                <button
                                    key={p.label}
                                    onClick={() => handleSelect(p)}
                                    className={`w-full text-right px-4 py-3 text-sm hover:bg-gray-50 dark:hover:bg-gray-700 transition border-b border-gray-50 dark:border-gray-700 last:border-0 ${dateRange.label === p.label ? 'text-indigo-600 font-bold bg-indigo-50 dark:bg-indigo-900/20' : 'text-gray-700 dark:text-gray-300'}`}
                                >
                                    {p.label}
                                </button>
                            ))}
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
};


// 2. KPI BAR (NOW WITH INVENTORY VALUE)
export const KPIBar: React.FC = () => {
    const { dateRange, currency, refreshKey, setKpiData } = useDashboard();
    const [stats, setStats] = useState<any>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        let active = true;
        const load = async () => {
            setLoading(true);
            try {
                const supabase = getSupabaseClient();
                if (!supabase) return;

                // 1. Sales Report
                const { data: salesData }: any = await supabase.rpc('get_sales_report_summary', {
                    p_start_date: dateRange.start.toISOString(),
                    p_end_date: dateRange.end.toISOString(),
                    p_zone_id: null,
                    p_invoice_only: false
                });

                // 2. Inventory Value (Try RPC, fallback to client-side limit)
                let totalInventoryValue = 0;
                try {
                    const { data: val, error } = await supabase.rpc('get_inventory_valuation');
                    if (!error && typeof val === 'number') {
                        totalInventoryValue = val;
                    } else {
                        // Fallback logic if RPC missing
                        const { data: stockData } = await supabase.rpc('get_inventory_stock_report', {
                            p_warehouse_id: null,
                            p_search: null,
                            p_limit: 1000
                        });

                        // Note: get_inventory_stock_report currently does NOT return cost. 
                        // So this will likely be 0 unless we join separately. 
                        // For 100% accuracy, the NEW RPC is required.
                        if (stockData && Array.isArray(stockData)) {
                            // Attempt to use 'current_cost_price' if it existed, but it doesn't.
                            // So we accept 0 as better than a random guess.
                            totalInventoryValue = 0;
                        }
                    }
                } catch (e) {
                    console.warn('Inventory Valuation Error:', e);
                }

                // 3. POs In Transit
                const { count: transitCount } = await supabase
                    .from('purchase_orders')
                    .select('*', { count: 'exact', head: true })
                    .in('status', ['shipped', 'processing']);

                if (active) {
                    const newStats = {
                        sales: salesData?.total_sales_accrual || 0,
                        orders: salesData?.total_orders_accrual || 0,
                        margin: salesData?.total_sales_accrual > 0
                            ? ((salesData?.gross_subtotal - salesData?.cogs) / salesData?.total_sales_accrual * 100)
                            : 0,
                        transit: transitCount || 0,
                        inventoryValue: totalInventoryValue
                    };
                    setStats(newStats);
                    setKpiData(newStats);
                }

            } catch (err) {
                console.error(err);
            } finally {
                if (active) setLoading(false);
            }
        };
        load();
        return () => { active = false; };
    }, [dateRange, refreshKey]);

    const cards = [
        {
            title: 'المبيعات',
            value: stats ? fmt(stats.sales) : '—',
            sub: currency,
            icon: Icons.CartIcon,
            color: 'text-emerald-600',
            bg: 'bg-emerald-50 dark:bg-emerald-900/20'
        },
        {
            title: 'قيمة المخزون',
            value: stats ? fmt(stats.inventoryValue) : '—',
            sub: currency,
            icon: Icons.DollarSign,
            color: 'text-blue-600',
            bg: 'bg-blue-50 dark:bg-blue-900/20'
        },
        {
            title: 'هامش الربح',
            value: stats ? stats.margin.toFixed(1) + '%' : '—',
            sub: 'إجمالي',
            icon: Icons.TrendingUpIcon,
            color: 'text-purple-600',
            bg: 'bg-purple-50 dark:bg-purple-900/20'
        },
        {
            title: 'طلبات الشراء',
            value: stats ? fmtInt(stats.transit) : '—',
            sub: 'قيد التنفيذ',
            icon: Icons.TruckIcon,
            color: 'text-orange-600',
            bg: 'bg-orange-50 dark:bg-orange-900/20'
        }
    ];

    return (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-2">
            {cards.map((c, i) => (
                <div key={i} className="bg-white dark:bg-gray-800 p-6 rounded-2xl shadow-sm border border-gray-100 dark:border-gray-700 flex items-center justify-between hover:shadow-md transition-shadow group">
                    <div>
                        <p className="text-sm text-gray-500 dark:text-gray-400 font-medium mb-1 group-hover:text-gray-700 dark:group-hover:text-gray-300 transition-colors">{c.title}</p>
                        {loading ? (
                            <Skeleton className="h-8 w-24" />
                        ) : (
                            <div className="flex items-baseline gap-1">
                                <h3 className={`text-2xl font-bold font-mono tracking-tight ${c.color}`}>{c.value}</h3>
                                <span className="text-xs text-gray-400 font-medium">{c.sub}</span>
                            </div>
                        )}
                    </div>
                    <div className={`p-4 rounded-xl ${c.bg} group-hover:scale-110 transition-transform`}>
                        <c.icon className={`w-6 h-6 ${c.color}`} />
                    </div>
                </div>
            ))}
        </div>
    );
};

// 3. INVENTORY SECTION (Alerts & Top Products)
export const InventorySection: React.FC = () => {
    const { currency, refreshKey } = useDashboard();
    const [topProducts, setTopProducts] = useState<any[]>([]);
    const [alerts, setAlerts] = useState<any[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        let active = true;
        const load = async () => {
            setLoading(true);
            try {
                const supabase = getSupabaseClient();
                if (!supabase) return;

                // 1. Top Products (By Revenue)
                const start = new Date(); start.setDate(1); start.setHours(0, 0, 0, 0);
                const end = new Date(); end.setHours(23, 59, 59, 999);

                const { data: products }: any = await supabase.rpc('get_product_sales_report_v9', {
                    p_start_date: start.toISOString(),
                    p_end_date: end.toISOString(),
                    p_zone_id: null
                });

                // 2. Alerts (Low Stock)
                const { data: stock }: any = await supabase.rpc('get_inventory_stock_report', {
                    p_warehouse_id: null,
                    p_search: null,
                    p_limit: 1000
                });

                if (active) {
                    const sortedProducts = (products || [])
                        .sort((a: any, b: any) => b.total_sales - a.total_sales)
                        .slice(0, 5);
                    setTopProducts(sortedProducts);

                    const lowStock = (stock || [])
                        .filter((item: any) => item.current_stock <= (item.min_stock || 5) && item.current_stock > 0)
                        .slice(0, 5);
                    setAlerts(lowStock);
                }
            } catch (err) {
                console.error(err);
            } finally {
                if (active) setLoading(false);
            }
        };
        load();
        return () => { active = false; };
    }, [refreshKey]);

    return (
        <div className="bg-white dark:bg-gray-800 p-6 rounded-2xl shadow-sm border border-gray-100 dark:border-gray-700 h-full flex flex-col gap-6">
            {/* Top Products */}
            <div>
                <h3 className="font-bold text-gray-800 dark:text-gray-200 mb-4 flex items-center gap-2 text-sm uppercase tracking-wider">
                    <Icons.Star className="w-4 h-4 text-amber-500" />
                    المنتجات الأكثر مبيعاً (هذا الشهر)
                </h3>
                {loading ? <Skeleton className="h-40 w-full" /> : (
                    <div className="space-y-4">
                        {topProducts.length === 0 ? <p className="text-sm text-gray-400 text-center py-4">لا توجد بيانات</p> :
                            topProducts.map((p, i) => (
                                <div key={i} className="group">
                                    <div className="flex justify-between text-xs mb-1 font-medium">
                                        <span className="text-gray-700 dark:text-gray-300 truncate w-3/4">{(p.item_name as any)?.ar || (p.item_name as any)?.en || 'منتج'}</span>
                                        <span className="text-gray-900 dark:text-white font-mono">{fmt(p.total_sale || p.total_sales)} {currency}</span>
                                    </div>
                                    <div className="h-2 w-full bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden">
                                        <div
                                            className="h-full bg-gradient-to-r from-amber-400 to-orange-500 rounded-full transition-all duration-1000"
                                            style={{ width: `${Math.min((p.total_sales / (topProducts[0]?.total_sales || 1)) * 100, 100)}%` }}
                                        />
                                    </div>
                                </div>
                            ))}
                    </div>
                )}
            </div>

            <div className="border-t border-gray-100 dark:border-gray-700 my-2"></div>

            {/* Alerts */}
            <div>
                <h3 className="font-bold text-gray-800 dark:text-gray-200 mb-4 flex items-center gap-2 text-sm uppercase tracking-wider">
                    <Icons.InfoIcon className="w-4 h-4 text-red-500" />
                    تنبيهات المخزون المنخفض
                </h3>
                {loading ? <Skeleton className="h-20 w-full" /> : (
                    <div className="space-y-3">
                        {alerts.length === 0 ? <p className="text-sm text-gray-400 text-center py-4">المخزون في حالة جيدة</p> :
                            alerts.map((item, i) => (
                                <div key={i} className="flex justify-between items-center text-sm p-2 bg-red-50 dark:bg-red-900/10 rounded-lg border border-red-100 dark:border-red-900/20">
                                    <span className="font-medium text-gray-700 dark:text-gray-300">{(item.item_name as any)?.ar || item.item_name}</span>
                                    <span className="font-bold text-red-600 bg-white dark:bg-gray-800 px-2 py-0.5 rounded shadow-sm text-xs">
                                        {item.current_stock} {item.unit_type || 'قطعة'}
                                    </span>
                                </div>
                            ))}
                    </div>
                )}
            </div>
        </div>
    );
};

// 4. SALES SECTION (Detailed SVG Chart + Toggle)
export const SalesSection: React.FC = () => {
    const { dateRange, refreshKey, currency } = useDashboard();
    const [data, setData] = useState<any[]>([]);
    const [loading, setLoading] = useState(true);
    const [hoverIndex, setHoverIndex] = useState<number | null>(null);
    const [viewMode, setViewMode] = useState<'all' | 'wholesale'>('all');

    useEffect(() => {
        let active = true;
        const load = async () => {
            setLoading(true);
            try {
                const supabase = getSupabaseClient();
                if (!supabase) return;

                const { data: stats }: any = await supabase.rpc('get_daily_sales_stats', {
                    p_start_date: dateRange.start.toISOString(),
                    p_end_date: dateRange.end.toISOString(),
                    p_zone_id: null,
                    p_invoice_only: viewMode === 'wholesale' // Simple filter logic
                });

                if (active) {
                    setData(stats || []);
                }
            } catch (err) {
                console.error(err);
            } finally {
                if (active) setLoading(false);
            }
        };
        load();
        return () => { active = false; };
    }, [dateRange, refreshKey, viewMode]);

    // Chart Calculations
    const maxSales = useMemo(() => Math.max(...data.map(d => Number(d.total_sales)), 100), [data]);
    const points = useMemo(() => {
        if (data.length < 2) return '';
        return data.map((d, i) => {
            const x = (i / (data.length - 1)) * 100;
            const y = 100 - (Number(d.total_sales) / maxSales) * 100;
            return `${x},${y}`;
        }).join(' ');
    }, [data, maxSales]);

    const areaPoints = useMemo(() => {
        if (!points) return '';
        return `0,100 ${points} 100,100`;
    }, [points]);

    return (
        <div className="bg-white dark:bg-gray-800 p-6 rounded-2xl shadow-sm border border-gray-100 dark:border-gray-700 h-full min-h-[400px] flex flex-col">
            <div className="flex justify-between items-center mb-6">
                <div className="flex items-center gap-4">
                    <h3 className="font-bold text-gray-800 dark:text-gray-200 flex items-center gap-2">
                        <Icons.TrendingUpIcon className="w-5 h-5 text-indigo-500" />
                        اتجاه المبيعات
                    </h3>

                    {/* Channel Toggle */}
                    <div className="flex bg-gray-100 dark:bg-gray-700 rounded-lg p-1">
                        <button
                            onClick={() => setViewMode('all')}
                            className={`px-3 py-1 text-xs font-medium rounded-md transition ${viewMode === 'all' ? 'bg-white dark:bg-gray-600 shadow text-indigo-600 dark:text-indigo-400' : 'text-gray-500 dark:text-gray-400'}`}
                        >
                            الكل
                        </button>
                        <button
                            onClick={() => setViewMode('wholesale')}
                            className={`px-3 py-1 text-xs font-medium rounded-md transition ${viewMode === 'wholesale' ? 'bg-white dark:bg-gray-600 shadow text-indigo-600 dark:text-indigo-400' : 'text-gray-500 dark:text-gray-400'}`}
                        >
                            جملة (فواتير)
                        </button>
                    </div>
                </div>

                <div className="text-sm text-gray-500 dark:text-gray-400 font-mono hidden sm:block">
                    Max: {fmtInt(maxSales)} {currency}
                </div>
            </div>

            <div className="bg-gray-50 dark:bg-gray-900 rounded-xl p-4 flex-1 relative overflow-hidden group">
                {loading ? (
                    <div className="absolute inset-0 flex items-center justify-center">
                        <Skeleton className="w-full h-full opacity-50" />
                    </div>
                ) : data.length < 2 ? (
                    <div className="absolute inset-0 flex items-center justify-center text-gray-400 text-sm">
                        لا توجد بيانات كافية للرسم البياني
                    </div>
                ) : (
                    <div className="relative w-full h-full min-h-[250px]">
                        {/* Tooltip Overlay */}
                        {hoverIndex !== null && data[hoverIndex] && (
                            <div
                                className="absolute bg-white dark:bg-gray-800 shadow-xl rounded-lg p-3 text-xs border border-gray-200 dark:border-gray-600 z-10 pointer-events-none transform -translate-x-1/2 -translate-y-full mb-2 transition-all duration-75"
                                style={{
                                    left: `${(hoverIndex / (data.length - 1)) * 100}%`,
                                    top: `${100 - (Number(data[hoverIndex].total_sales) / maxSales) * 100}%`
                                }}
                            >
                                <div className="font-bold text-indigo-600 font-mono mb-1">{fmt(data[hoverIndex].total_sales)} {currency}</div>
                                <div className="text-gray-500">{new Date(data[hoverIndex].day_date).toLocaleDateString('ar-EG')}</div>
                                <div className="text-gray-400 mt-1">{data[hoverIndex].order_count} طلب</div>
                            </div>
                        )}

                        <svg
                            viewBox={`0 0 100 100`}
                            preserveAspectRatio="none"
                            className="w-full h-full overflow-visible"
                            onMouseLeave={() => setHoverIndex(null)}
                            onMouseMove={(e) => {
                                const rect = e.currentTarget.getBoundingClientRect();
                                const x = e.clientX - rect.left;
                                const percent = x / rect.width;
                                const index = Math.round(percent * (data.length - 1));
                                setHoverIndex(Math.max(0, Math.min(index, data.length - 1)));
                            }}
                        >
                            <defs>
                                <linearGradient id="gradient" x1="0" x2="0" y1="0" y2="1">
                                    <stop offset="0%" stopColor="#6366f1" stopOpacity="0.3" />
                                    <stop offset="100%" stopColor="#6366f1" stopOpacity="0" />
                                </linearGradient>
                            </defs>

                            <line x1="0" y1="25" x2="100" y2="25" stroke="currentColor" strokeOpacity="0.05" vectorEffect="non-scaling-stroke" />
                            <line x1="0" y1="50" x2="100" y2="50" stroke="currentColor" strokeOpacity="0.05" vectorEffect="non-scaling-stroke" />
                            <line x1="0" y1="75" x2="100" y2="75" stroke="currentColor" strokeOpacity="0.05" vectorEffect="non-scaling-stroke" />

                            <polygon points={areaPoints} fill="url(#gradient)" />

                            <polyline points={points} fill="none" stroke="#6366f1" strokeWidth="3" vectorEffect="non-scaling-stroke" strokeLinecap="round" strokeLinejoin="round" />

                            {hoverIndex !== null && (
                                <>
                                    <line
                                        x1={(hoverIndex / (data.length - 1)) * 100}
                                        y1="0"
                                        x2={(hoverIndex / (data.length - 1)) * 100}
                                        y2="100"
                                        stroke="#6366f1"
                                        strokeDasharray="2 2"
                                        strokeWidth="1"
                                        vectorEffect="non-scaling-stroke"
                                        opacity="0.5"
                                    />
                                    <circle
                                        cx={(hoverIndex / (data.length - 1)) * 100}
                                        cy={100 - (Number(data[hoverIndex].total_sales) / maxSales) * 100}
                                        r="6"
                                        fill="#fff"
                                        stroke="#6366f1"
                                        strokeWidth="2"
                                        vectorEffect="non-scaling-stroke"
                                        className="animate-ping absolute opacity-20"
                                    />
                                    <circle
                                        cx={(hoverIndex / (data.length - 1)) * 100}
                                        cy={100 - (Number(data[hoverIndex].total_sales) / maxSales) * 100}
                                        r="4"
                                        fill="#fff"
                                        stroke="#6366f1"
                                        strokeWidth="2"
                                        vectorEffect="non-scaling-stroke"
                                    />
                                </>
                            )}
                        </svg>
                    </div>
                )}
            </div>

            <div className="mt-4 flex justify-between items-center text-xs text-gray-400">
                <span>{data[0]?.day_date ? new Date(data[0].day_date).toLocaleDateString('ar-EG') : ''}</span>
                <span>{data[data.length - 1]?.day_date ? new Date(data[data.length - 1].day_date).toLocaleDateString('ar-EG') : ''}</span>
            </div>
        </div>
    );
};

// 5. PURCHASING SECTION (Simple Status Stack)
export const PurchasingSection: React.FC = () => {
    const { refreshKey } = useDashboard();
    const [poStats, setPoStats] = useState<Record<string, number>>({});
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        let active = true;
        const load = async () => {
            setLoading(true);
            try {
                const supabase = getSupabaseClient();
                if (!supabase) return;

                const { data }: any = await supabase
                    .from('purchase_orders')
                    .select('status');

                if (active && data) {
                    const counts: Record<string, number> = {};
                    data.forEach((po: any) => {
                        counts[po.status] = (counts[po.status] || 0) + 1;
                    });
                    setPoStats(counts);
                }
            } catch (err) {
                console.error(err);
            } finally {
                if (active) setLoading(false);
            }
        };
        load();
        return () => { active = false; };
    }, [refreshKey]);

    const statuses = [
        { key: 'pending', label: 'قيد الانتظار', color: 'bg-yellow-500' },
        { key: 'ordered', label: 'تم الطلب', color: 'bg-blue-500' },
        { key: 'shipped', label: 'تم الشحن', color: 'bg-orange-500' },
        { key: 'delivered', label: 'وصلت', color: 'bg-green-500' },
        { key: 'cancelled', label: 'ملغي', color: 'bg-gray-400' },
    ];

    const total = Object.values(poStats).reduce((a, b) => a + b, 0) || 1;

    return (
        <div className="bg-white dark:bg-gray-800 p-6 rounded-2xl shadow-sm border border-gray-100 dark:border-gray-700 h-full flex flex-col">
            <h3 className="font-bold text-gray-800 dark:text-gray-200 mb-6 flex items-center gap-2">
                <Icons.TruckIcon className="w-5 h-5 text-indigo-500" />
                توزيع حالة المشتريات
            </h3>

            {loading ? <Skeleton className="h-64 w-full" /> : (
                <div className="flex-1 flex flex-col justify-center gap-4">
                    {/* Stacked Bar */}
                    <div className="h-4 w-full flex rounded-full overflow-hidden bg-gray-100 dark:bg-gray-700">
                        {statuses.map(s => {
                            const count = poStats[s.key] || 0;
                            if (count === 0) return null;
                            const pct = (count / total) * 100;
                            return (
                                <div key={s.key} className={`h-full ${s.color}`} style={{ width: `${pct}%` }} title={`${s.label}: ${count}`} />
                            );
                        })}
                    </div>

                    {/* Legend */}
                    <div className="space-y-3 mt-4">
                        {statuses.map(s => (
                            <div key={s.key} className="flex justify-between items-center text-sm">
                                <div className="flex items-center gap-2">
                                    <div className={`w-3 h-3 rounded-full ${s.color}`} />
                                    <span className="text-gray-600 dark:text-gray-400">{s.label}</span>
                                </div>
                                <span className="font-bold font-mono text-gray-900 dark:text-gray-200">{poStats[s.key] || 0}</span>
                            </div>
                        ))}
                    </div>
                </div>
            )}
        </div>
    );
};
